# 인프라 변경 이력 요약

완료된 설계 spec과 구현 plan의 핵심 결정만 보존한다. 현재 운영 절차는
`TEAM_OPERATIONS_RUNBOOK.md`와 `TERRAFORM_DEV.md`를 우선한다.

## 2026-07-18: autoresearch 네임스페이스 팀원 접근 RBAC (#252)

- `autoresearch`(앱) 네임스페이스에 팀 RBAC가 전혀 없어 팀원 5명 전원이 앱/모델
  파드를 `kubectl` 조회·`port-forward`하지 못했다(`airflow`·`mlflow`·`monitoring`
  에는 팀 접근이 있는데 정작 앱 파드가 도는 `autoresearch`만 누락). 접근 감사에서 발견.
- `mlflow-k8s`(#236)와 동일 패턴으로 `terraform/admin/autoresearch-k8s`에 최소 권한
  부여: built-in ClusterRole `view`(secret 제외 read) namespace RoleBinding +
  `pods/portforward` create 전용 Role. 대상은 `autoresearch_viewer_user_emails`(로컬 tfvars).
- 최소권한 경계: `pods/exec`·write·cluster-admin 미부여. plan 검증: 11 add(Role 1 +
  계정별 RoleBinding 2)/0 change/0 destroy. 롤백은 tfvars에서 계정 제거 후 apply.

## 2026-07-18: 코드 아카이브 배포용 GCS 버킷·업로더 SA·WIF (#238)

- 앱 코드 배포 파이프라인(main 머지 시 코드 tar.gz를 GCS 업로드, GKE
  `autoresearch-app` 파드가 시작 시 다운로드) 인프라를 `code_artifacts.tf`로 추가한다.
  앱 구현은 `SKYAHO/Autoresearch#180`·`#182`, 워크플로우 `code-archive.yml`.
- 리소스: 코드 아카이브 전용 버킷 `<project_id>-code-artifacts`(서울, UBLA, public
  차단, versioning 없음) + 업로더 SA `autoresearch-dev-code-uploader` + WIF 바인딩
  + 버킷 IAM 2종.
- 최소권한 경계: 업로더 SA는 **정확한 `code-archive.yml@refs/heads/main`
  `workflow_ref`만** 가장 허용(#175/#221 관례, 임의 브랜치·워크플로우 차단). 권한은
  **버킷 한정** `roles/storage.objectAdmin`(latest.txt 덮어쓰기, 프로젝트 수준 아님).
  파드 GSA(`gke_app`)는 같은 버킷 `roles/storage.objectViewer`(read only).
- `SKYAHO/Autoresearch`는 이미 WIF 허용 목록이라 bootstrap 변경 불필요. 비용 영향
  미미. output `code_artifacts_bucket_name`·`code_uploader_service_account_email`를
  앱 리포 secret(`CODE_ARTIFACTS_BUCKET`·`GCS_CODE_UPLOADER_SA`)에 등록(앱팀).

## 2026-07-18: MLflow UI 내부 ILB 노출 (#244)

- MLflow UI를 Airflow(#48)와 동일 패턴으로 **VPC 내부 전용 ILB + private DNS**로
  노출한다. 인증(oauth2-proxy)은 앞단에서 계속 강제하고 `mlflow`(5000)은 ClusterIP
  내부 전용을 유지한다(미인증 우회 차단).
- 1단계(PR #245): `dns.tf`에 예약 내부 IP `autoresearch-dev-mlflow-ilb`
  (`SHARED_LOADBALANCER_VIP`, dev subnet → **10.10.0.22**) + A레코드
  `mlflow.dev.autoresearch.internal`(기존 `internal` zone 재사용) + output. dev root
  apply 시 #243 airflow scheduler WI 바인딩이 함께 대기 중이라 전체 3 add로 reconcile.
- 2단계(PR #246): `deploy/mlflow/oauth2-proxy.yaml`의 Service를 internal
  LoadBalancer로 flip(`networking.gke.io/load-balancer-type: Internal`,
  `loadBalancerIP: 10.10.0.22`). ArgoCD sync로 배포.
- **접근**: Bastion(#47) 터널 `-L 4180:mlflow.dev.autoresearch.internal:4180` →
  브라우저 `localhost:4180`. 터널이 DNS를 목적지로 쓰고 Host는 localhost라 OAuth
  redirect URI(`localhost:4180`)가 불변 → **콘솔 재등록 불필요**. port-forward(#236)도 유지.
- 검증: ArgoCD Synced/Healthy, Service EXTERNAL-IP=10.10.0.22, in-cluster probe
  `/ping`→200·`/`(미인증)→403(인증 강제), `mlflow:5000` ClusterIP 유지(미노출).
- 롤백: Service를 ClusterIP로 되돌리면 ILB 제거. 예약 IP/DNS는 dev root에서 제거·apply.

## 2026-07-18: MLflow 팀원 port-forward RBAC (#236)

- `mlflow` 네임스페이스에 RBAC가 전혀 없어 Model Training 담당자가 실배포된
  MLflow UI를 `kubectl port-forward`로 검증하지 못했다. `airflow-k8s`의
  `installer_user_emails` 패턴을 따라 `terraform/admin/mlflow-k8s`에 최소 권한을
  부여한다: built-in ClusterRole `view`(secret 제외 read) namespace RoleBinding +
  `pods/portforward` create 전용 Role. 대상은 `mlflow_viewer_user_emails`(로컬
  tfvars, 팀원 5명).
- 최소권한 경계: `pods/exec`·write·cluster-admin은 부여하지 않는다. apply 결과
  live 검증 — `can-i create pods --subresource=portforward` yes, `pods/exec`·
  `secrets` no, `kubectl port-forward svc/mlflow` 정상.
- 롤백: 대상 계정을 tfvars에서 제거 후 apply하면 해당 RoleBinding만 삭제된다.

## 2026-07-18: airflow→MLflow tracking egress 허용 (#234, PR #235)

- `airflow` 네임스페이스의 deny-by-default egress NetworkPolicy에 `mlflow.mlflow:5000`
  규칙이 없어 향후 KubernetesPodOperator CTR 학습 Pod가 tracking server에
  접속할 수 없었다. `airflow-k8s`의 egress에 두 규칙을 추가한다: `cluster_services_cidr`
  ipBlock TCP 5000(주 경로 — Calico가 egress를 DNAT 이전 Service VIP 기준으로
  평가)과 `mlflow` namespace selector TCP 5000(DNAT 이후 dataplane 대비 fallback,
  기존 kube-dns 패턴과 동일).
- NetworkPolicy 1개 in-place 변경만, 다른 egress 규칙 영향 없음. apply 후 live
  검증 — airflow Pod → `http://mlflow.mlflow:5000/health` HTTP 200.

## 2026-07-18: MLflow 설계 문서 as-built 정정 (#197)

- MLflow 운영 구조 설계 spec(#91)을 실제 구현과 대조해 정정한다(문서만, 동작 무변경).
  리뷰에서 문서↔구현 불일치가 확인됐다: backend URI를 완성 단일 key/`$(VAR)`에서
  실제 `POSTGRES_*` 분해 Secret + `sh -c` 조립으로, GSA IAM을 실제 부여값으로,
  namespace(`autoresearch`→전용 `mlflow`)·신규 admin root `mlflow-k8s`·deploy 위치·
  OAuth2-proxy를 as-built로 반영(15절 신설). 확정 as-built는 runbook 기준.
- **보안 발견(후속 검토)**: MLflow GSA에 project-level `roles/cloudsql.client`와 DB
  password secret resource-level `roles/secretmanager.secretAccessor`가 부여돼 있으나,
  현재 런타임 경로(private IP 직접 연결 + operator 주입 K8s Secret `mlflow-db` 읽기)엔
  둘 다 불필요하다 → 최소권한 축소 후보.

## 2026-07-16: 팀원 BigQuery 분석 권한을 별도 admin state로 관리 (#215)

- 팀원 Google 계정에 프로젝트 수준 `roles/bigquery.jobUser`와
  `autoresearch_dev_analytics`·`feast_offline_store` dataset별
  `roles/bigquery.dataEditor`를 추가한다. 사람 IAM은 기존처럼
  `terraform/admin/gke-team-access`의 로컬 `terraform.tfvars`와 별도 state로만
  관리해 이메일과 off-boarding churn이 일반 dev PR plan에 노출되지 않게 한다.
- 최소권한 경계: jobUser는 BigQuery job 생성에만, dataEditor는 두 dataset에만
  부여한다. 프로젝트 수준 `roles/bigquery.dataEditor`, `roles/editor`,
  `roles/owner`는 부여하지 않는다. jobUser의 쿼리 비용은 실행 시
  `maximum_bytes_billed` 등 job 수준 제한으로 제어한다.
- 비용·리전 영향 없음(IAM binding만 추가). 롤백/퇴사는 로컬 tfvars에서 해당
  계정을 제거한 뒤 apply하여 해당 계정의 GKE·Bastion·BigQuery IAM member만
  제거한다.

## 2026-07-17: MLflow Cloud SQL 전용 DB/user + Secret Manager (#93)

- #91 설계에 따라 MLflow backend를 **기존 Cloud SQL `autoresearch-dev-pg` 재사용**으로
  구성한다. 신규 인스턴스 없이 전용 `google_sql_database`(`mlflow`) +
  `google_sql_user`(`mlflow`)로 Airflow/앱과 **논리 분리**(8회차 "DB 외부화").
- 비밀번호는 전용 `random_password.mlflow_db_password`(24자) → Secret Manager
  `autoresearch-dev-mlflow-db-password`. state 평문 저장 한계는 기존 `db_app_password`와
  동일(GCS backend 접근제어로 완화, dev accept).
- 최소권한: MLflow GSA에 **secret resource-level `secretAccessor`** + project
  `roles/cloudsql.client`. private IP 접속(NetworkPolicy는 #94 mlflow-k8s).
- 배치: DB/user=cloud_sql.tf, secret=secret_manager.tf, GSA IAM=mlflow.tf(리포 kind 패턴).
- targeted plan: 8 add(#92 GSA 포함) / 0 change / 0 destroy. 기존 SQL 인스턴스 무변경.
  #92와 함께 apply 예정. 배포는 #94.

## 2026-07-17: MLflow UI OAuth2-proxy 인증 (#232)

- MLflow UI 앞단에 OAuth2-proxy를 두어 **Google 로그인 + 명시적 허용 이메일 목록**으로
  접근을 제한한다("정해진 계정만"). 기존 네트워크 격리(ClusterIP/port-forward)에
  개인 인증 계층 추가.
- `deploy/mlflow/oauth2-proxy.yaml`: oauth2-proxy Deployment + Service(4180).
  upstream=`mlflow.mlflow:5000`, sign-in 페이지 유지(에어플로우식). 사용자는
  `mlflow-oauth-proxy`로 port-forward.
- **보안**: client-id/secret·cookie-secret·허용 이메일 목록은 공개 저장소에 두지 않고
  operator 주입 Secret `mlflow-oauth`(`--from-file`, read -s로 값 미노출).
  직접 mlflow Service는 내부 전용 유지.
- 선행(사람): GCP 콘솔 OAuth client 생성(redirect `http://localhost:4180/oauth2/callback`).
  NetworkPolicy는 기존 443 egress로 커버(변경 없음).

## 2026-07-17: MLflow 운영 runbook (#95)

- 배포·검증 완료된 MLflow 스택 기준으로 운영 runbook을 작성한다
  (`docs/MLFLOW_OPERATIONS_RUNBOOK.md`, README 인덱스 등록).
- 포함: 접속(port-forward), 클라이언트 실험/모델 등록(proxy 모드라 GCS 자격 불필요),
  시크릿 주입·DB 비번 로테이션(#213 `--from-env-file`), backend/artifact 백업·복구
  (Cloud SQL PITR, GCS soft delete), GitOps 배포·업데이트, 장애 대응(OOM #229·
  probe·backend·artifact 403 등)·진단 명령.
- 이로써 MLflow 에픽(#91 설계 → #92 GCS → #93 Cloud SQL → #94 배포 → #95 runbook)
  전체 완료. UI 인증(OAuth2-proxy)·내부 ILB는 후속 과제.

## 2026-07-17: MLflow tracking server 배포 구성 (#94)

- #91 설계에 따라 MLflow tracking server를 ArgoCD로 배포하는 구성을 추가한다(코드).
  실제 배포 apply는 단계별 승인 후.
- **이미지**: 앱 저장소 `deploy/mlflow/Dockerfile`(v2.22.1 + psycopg2 +
  google-cloud-storage)을 **인프라 Cloud Build로 GAR에 빌드**(#203 방식) —
  `autoresearch-mlflow@sha256:21f1bde1…`. 앱팀이 파이프라인에 얹으면 image re-point.
- **`terraform/admin/mlflow-k8s`**(신규 root): namespace `mlflow` + KSA `mlflow`(WI) +
  deny-by-default egress NetworkPolicy(Cloud SQL PSA 5432, GCS/API 443, DNS, WI metadata).
- **`deploy/mlflow`**(plain 매니페스트): Deployment(`--serve-artifacts`, GCS proxy) +
  Service(ClusterIP, 내부 전용). backend는 Cloud SQL private IP.
- **`argocd-k8s`**: AppProject destination `mlflow` + Application `mlflow`(manual sync,
  CreateNamespace=false).
- **보안**: UI 외부 노출 0(ClusterIP), GCS는 WI 인증(키 없음), **DB host(private IP)·비번은
  공개 저장소에 넣지 않고 operator 주입 K8s Secret `mlflow-db`**(#213 --from-env-file 패턴,
  mlflow-k8s README)에서만 주입.

## 2026-07-17: MLflow artifact 버킷 중복 해소 — 기존 수동 버킷 adopt (#226)

- #92 apply 후, 앱팀이 **수동 생성한 기존 MLflow 버킷**
  `ar-infra-501607-autoresearch-mlflow-artifacts`(2026-07-14, `mlflow-artifacts/`
  데이터 보유, 어떤 IaC도 관리 안 함)를 발견. #92가 만든 빈 중복 버킷
  `autoresearch-dev-mlflow-artifacts`을 제거하고 **기존 버킷을 adopt**했다.
- 절차: 중복 버킷 `state rm` + 삭제(빈 상태) → `mlflow.tf` 버킷명을
  `${project_id}-${name_prefix}-mlflow-artifacts`로 변경 → `terraform import` →
  apply. **데이터 유지, destroy 0**(2 add / 1 change / 0 destroy).
- 부수 보안 강화: adopt 시 `public_access_prevention` **inherited → enforced**,
  라벨 부착, MLflow GSA에 objectAdmin+legacyBucketReader 부착.
- 교훈: 설계(#91) 시 라이브 GCS 버킷을 열거하지 않아 중복이 발생. 향후 신규
  저장소 설계는 **기존 리소스 실사 포함**.

## 2026-07-17: MLflow artifact GCS bucket + 전용 GSA (#92)

- #91 설계에 따라 MLflow의 artifact 저장소와 전용 인증 주체를 `mlflow.tf`(feature
  파일, redis.tf/airflow.tf 패턴)로 신설한다.
- `autoresearch-dev-mlflow-artifacts` GCS 버킷: uniform access, public access 차단,
  `prevent_destroy`, **7일 soft delete 복구층**(#179 교훈). versioning/lifecycle
  삭제 없음(모델 artifact는 영속).
- MLflow **전용 GSA `autoresearch-dev-mlflow`**(app GSA와 분리 — GCS 자격을 MLflow에만)
  + WI 바인딩(`svc.id.goog[mlflow/mlflow]`, KSA는 #94에서 생성).
- 버킷 IAM(resource-level): `storage.objectAdmin` **+ `storage.legacyBucketReader`**
  (#204 교훈: objectAdmin엔 `storage.buckets.get` 없어 GCS 클라이언트 403 방지).
- targeted plan: 5 add / 0 change / 0 destroy. 실제 apply는 별도 승인 후.
- backend(Cloud SQL DB/user)는 #93, 배포는 #94.

## 2026-07-17: MLflow 운영 구조 설계 (#91)

- MLflow Tracking + Model Registry의 운영 구조를 확정하고 후속 구현(#92~#95) 범위를
  분리했다. 설계 `superpowers/specs/2026-07-17-mlflow-operating-design.md`, 순서
  `superpowers/plans/2026-07-17-mlflow-rollout.md`.
- 핵심 결정: 배포=**ArgoCD Application**(`deploy/mlflow`, monitoring/argo-rollouts와
  일관), namespace=신규 admin root **`mlflow-k8s`**, backend=**기존 Cloud SQL 재사용 +
  전용 DB/user 분리**, artifact=**신규 GCS 버킷 + proxy 모드**(GCS 자격은 서버에만),
  이미지=**앱 저장소 커스텀 이미지 참조**(경계 분리), UI=**내부 전용·외부 노출 금지**,
  인증=**전용 GSA + WI + 최소 IAM**(SA key 없음).
- 보안: 외부 노출 0, resource-level IAM, Secret Manager, feast IAM 교훈(`storage.buckets.get`
  → legacyBucketReader) 선반영.
- 리소스 변경 없음(설계 문서만). 실제 리소스는 #92~#95에서 사용자 승인 후.

## 2026-07-16: 시크릿 주입 런북을 --from-env-file로 전환 (보안 P1, #213)

- 운영 문서의 `kubectl create secret --from-literal=<값>` 예시가 실제 시크릿을
  명령행 인수에 넣어 셸 히스토리·프로세스 목록에 노출될 수 있던 것을,
  권한 제한 임시 env 파일 + `--from-env-file` + 정리 패턴으로 교체한다.
  - bash(타이핑 값: Grafana OAuth secret, grafana admin-password): `read -s`로
    입력받아 화면·히스토리에 남기지 않고, `umask 077` 임시파일(0600)에 써서
    `--from-env-file`로 주입, `trap ... EXIT`로 폐기.
  - PowerShell(gcloud→변수: airflow env): ACL 제한 임시파일 + `--from-env-file`,
    `finally`에서 파일·변수 폐기.
- 대상: `docs/GRAFANA_OPERATIONS_RUNBOOK.md`, `docs/TERRAFORM_DEV.md`(2곳).
- 검증: `kubectl --from-env-file --dry-run=client`로 동등 Secret 생성 확인,
  임시파일 권한 0600 확인.

## 2026-07-16: Terraform plan 원문 공개 게시 최소화 (보안 P2, #211)

- 공개 저장소에서 `terraform-plan.yml`(PR 코멘트, 최대 60k)과
  `terraform-drift.yml`(이슈, 최대 20k)이 plan 원문을 게시하고 마스킹은
  `user:` PII만(denylist) 대상이던 것을, **allowlist로 전환**한다.
- 공개 게시물에는 `# <addr> will be/must be ...` 리소스 주소 헤더와
  `Plan:`/`No changes` 요약 라인만 올린다(`grep`로 추출, 속성 diff 라인 제외 =
  값 노출 없음). plan 원문은 runner 임시파일에만 두고 job 종료 시 폐기한다.
- plan 오류 시에는 오류 원문 대신 **Actions 실행 링크 + exit code만** 게시한다
  (오류 텍스트에 섞일 수 있는 민감정보 차단).
- 근거: 저장소가 public이고 dev root가 실제 비밀 자재(`db_app_password`
  random_password→secret_version, redis CA)를 다룬다. Terraform이
  `(sensitive value)`로 redact하지만, 공개·영구 게시에서 denylist 갭 하나가 곧
  유출+로테이션으로 이어지므로 게시 표면 자체를 줄인다.
- 합성 plan으로 allowlist 검증: 실제 값(이메일·비밀번호·sensitive)과 속성
  diff 라인이 요약에 포함되지 않음을 확인.

## 2026-07-15: ArgoCD 임의 워크로드 실배포 경로 검증 (#208)

- ArgoCD가 plain 매니페스트(Deployment/Service)를 git에서 sync 배포하는 경로를
  임시 샘플(`deploy/sample-app`, nginx)로 실증했다. 기존 monitoring·argo-rollouts는
  helm_release adopt 사례라 신규 앱 배포 경로는 이 검증으로 처음 확인했다.
- 결과: Application `sample-app` Synced/Healthy, pod Running, Service HTTP 200,
  ArgoCD automated sync가 배포(수동 kubectl apply 아님).
- 핵심 함정: `CreateNamespace=true`는 cluster-scoped Namespace 생성이라 최소권한
  AppProject(`clusterResourceWhitelist`에 Namespace 없음)에서 sync 실패
  ("synchronization tasks are not valid"). **destination namespace 선생성으로 우회**
  — clusterResourceWhitelist를 넓히지 않는다. 실제 앱은 namespace를 Terraform이
  소유(`CreateNamespace=false`).
- **임시 검증**으로 수행 후 Application·AppProject destination·매니페스트를 제거하고
  namespace를 삭제했다. 절차·결과는 [`ARGOCD_OPERATIONS_RUNBOOK.md`](ARGOCD_OPERATIONS_RUNBOOK.md)의
  "임의 워크로드 실배포 검증" 절에 기록.
  영구 샘플은 유지하지 않는다(최소권한, sample-guestbook 제거 취지 일관).

## 2026-07-15: monitoring 스택 앱 메트릭 e2e 검증 재실증·runbook 기록 (#206)

- monitoring 스택(kube-prometheus-stack, ArgoCD 관리)의 관측 파이프라인을
  테스트 워크로드로 재실증했다: 앱 `/metrics`(Prometheus 형식) → ServiceMonitor →
  Prometheus scrape(`up=1`) → 저장 → Grafana datasource proxy 조회
  (`status: success`, `count=8`). 전 경로 동작 확인.
- 절차·매니페스트·실측 결과를 [`GRAFANA_OPERATIONS_RUNBOOK.md`](GRAFANA_OPERATIONS_RUNBOOK.md)의
  "앱 메트릭 e2e 검증" 절에 기록해 GitHub에 영속화했다(그간 검증 결과가 로컬 문서에만 있었음).
- 핵심 재현 조건: ServiceMonitor 라벨 `release: kube-prometheus-stack` 필수,
  `serviceMonitorNamespaceSelector={}`라 전용 검증 namespace 사용 가능. Grafana
  admin 자격은 operator 주입 시크릿 `grafana-admin-credentials`.
- GCP/Terraform 리소스 변경 없음(임시 K8s 워크로드만, 검증 후 namespace 삭제).
- 범위 밖(후속): ArgoCD를 통한 임의 워크로드 실배포(git manifest + AppProject
  destination 필요), Vault 시크릿 주입은 진행하지 않음(Vault 드랍 결정).

## 2026-07-15: feast materialize IAM 누락 보강 — storage.buckets.get·bigquery.readsessions (#204)

- #203 Feast ↔ Redis Cluster GKE 실연결 검증에서, feast materialize가 실제로
  요구하지만 IaC에 누락된 IAM 2종을 발견해 보강한다. 둘 다 `objectAdmin`·
  `jobUser`에 포함되지 않으며 feast 소비자 SA 3종(`gke_app`·`airflow`·
  `airflow_batch`)에 공통 잠복했다.
  - `storage.buckets.get`: feast GCS registry가 `bucket.reload()`로 bucket
    메타데이터를 조회한다. feast registry·staging bucket에
    `roles/storage.legacyBucketReader`를 추가해 딱 이 권한만 보강한다.
  - `bigquery.readsessions.create`: feast가 offline store(BigQuery)를 BigQuery
    Storage Read API로 읽는다. project-level `roles/bigquery.readSessionUser`를
    추가한다.
- 최소권한 원칙: 넓은 `storage.admin`/`bigquery.admin` 대신 필요한 권한만 담은
  predefined role을 additive(`_iam_member`)로 추가한다. 기존 바인딩은 불변.
- 비용 영향 없음(IAM 바인딩 추가만). 리전 변화 없음.
- 검증: 임시 부여 상태에서 #203 전 판정(dry-run `redis_ping`·shard 2·materialize
  `succeeded`·`get_online_features` 실값) 통과 확인 후 코드화. merge 후 apply가
  임시 부여를 정식 관리로 재조정한다.
- 롤백: 추가한 `_iam_member` 리소스를 revert 후 apply하면 바인딩만 제거된다.

## 2026-07-15: data lake 테이블 dt 파티션 IaC 소유권 경계 (#199)

- `feast_offline_store` dataset의 `data_lake_action_log`,
  `data_lake_youtube_trending_kr`를 `google_bigquery_table`로 코드화해 테이블
  재생성 시에도 `dt` 일 단위 파티셔닝을 보장한다. 구조(존재·파티셔닝·labels)는
  이 저장소(Terraform)가, 스키마/데이터는 앱 저장소
  `SKYAHO/Autoresearch`의 `scripts/load_raw_to_bigquery.py`(autodetect +
  WRITE_TRUNCATE, 멱등)가 소유하며 Terraform은 `ignore_changes = [schema]`로
  경계를 분리한다.
- 실제 GCP에는 두 테이블이 이미 DAY/dt 파티션으로 존재하므로 merge 후
  `terraform import`로 state에 편입한다. `deletion_protection = true`로 파티셔닝
  변경에 따른 테이블 교체를 차단한다.
- 비용 영향 없음: 테이블 리소스 자체는 무과금이고 파티셔닝은 쿼리 스캔 비용을
  절감하는 방향이다. 리전 변화 없음(`asia-northeast3`).
- 롤백: `terraform state rm`으로 state에서만 제거한 뒤 코드를 revert한다. 실제
  테이블과 데이터는 유지된다.

## 2026-07-14: application digest 승격과 Airflow GKE 자동 배포 기반 (#187)

- WIF provider에 `workflow_ref` mapping을 추가하고 application GAR pusher를
  정확한 `release.yml@refs/heads/main` workflow로 제한했다. release event의 tag
  `ref` 때문에 정상 발행이 거부되던 경계를 바로잡는다.
- `Autoresearch-airflow@refs/heads/main` 전용
  `autoresearch-dev-airflow-cd` GSA를 추가했다.
- GCP 권한은 `roles/container.clusterViewer`, Kubernetes 권한은 `airflow`
  namespace의 `admin` RoleBinding으로 분리했다. DNS endpoint를 사용하므로 IP
  allowlist는 확장하지 않는다.
- 적용 순서는 bootstrap → dev → admin root이며, 이 변경 자체는 apply하지 않는다.

## 2026-07-14: argo-rollouts ArgoCD 이관 (#186, GitOps 파일럿 확장)

- monitoring(#183) 파일럿에 이어 `helm_release.argo_rollouts`를 ArgoCD Application
  `argo-rollouts`로 무중단 이관했다. source는 infra repo `deploy/argo-rollouts/`
  umbrella chart(argo-rollouts 2.41.0 dependency + Chart.lock).
- releaseName을 기존 release와 동일한 `argo-rollouts`로 고정해 CRD/ClusterRole/
  ClusterRoleBinding을 재생성 없이 adopt. `removed { destroy=false }`로 helm_release를
  state에서만 제거(namespace·NetworkPolicy 경계는 Terraform 유지).
- AppProject는 destinations에 `argo-rollouts`만 추가하고 clusterResourceWhitelist는
  무변경(monitoring이 이미 CRD/ClusterRole/ClusterRoleBinding 허용, argo-rollouts는
  webhook 없음). 실행 중 Rollout CR 0개라 컨트롤러 adopt 영향 없음.
- 구현은 orca 병렬 fan-out(3개 codex 에이전트, disjoint 영역)으로 분담 후 통합.
- 설계: `superpowers/specs/2026-07-14-argo-rollouts-argocd-migration-design.md`.

## 2026-07-14: monitoring 스택 ArgoCD 이관 (#183)

- GitOps 파일럿. kube-prometheus-stack을 Terraform helm_release에서 ArgoCD
  Application으로 이관했다. chart/values는 infra repo `deploy/monitoring/`
  umbrella chart(kube-prometheus-stack 87.12.1 dependency)로, 배포는 argocd-k8s의
  Application(manual sync, ServerSideApply)이 관리한다.
- monitoring-k8s root는 GITOPS_STRATEGY 책임 분리대로 namespace·port-forward
  RBAC만 유지(helm_release·helm-values·helm provider·grafana_admin_* 변수 제거).
- AppProject를 확장했다: infra repo sourceRepo, monitoring destination,
  clusterResourceWhitelist(CRD/ClusterRole/webhook — kube-prometheus-stack 필요분만).
- 발견: Grafana admin existingSecret 설정이 values가 아니라 helm_release set
  블록에 있어, umbrella values로 옮기지 않으면 admin 로그인이 깨질 뻔했다.
- 무중단 adopt(state rm → 코드 제거 → Application sync)로 실행 중 스택 인수.
  operator 주입 secret은 chart 밖이라 미관리. 롤백은 helm_release import.

## 2026-07-14: Vault 평문 위협 게이트 강화 (#177)

- Codex adversarial review medium finding. Vault가 평문(tlsDisable)이라
  문서로만 실 secret을 금지하고 기술적 강제가 없었다.
- 판단: 회전 자동화 없는 self-signed TLS를 지금 켜는 것은 새 부채라 과잉.
  대신 (a) 위협 모델을 명확화(consumer 부재 + NetworkPolicy로 노출 표면이
  vault ns 내부 국한 — #136), (b) 실 secret 이관 전 하드 게이트 체크리스트
  (TLS+cert 회전, consumer 연동, audit, Secret Manager 역할 경계)를
  runbook/README/values에 명시적 게이트로 확립.
- TLS 활성화(cert-manager/Vault PKI)는 실 secret/ESO 연동의 선행 조건으로
  별도 마일스톤 이슈에 연결.

## 2026-07-14: ES snapshot bucket soft delete 추가 (#176)

- Codex adversarial review high finding. snapshot GSA의 objectAdmin(SLM
  삭제에 필요)과 soft delete 0(복구 불가)이 결합돼, 침해/오작동/잘못된
  SLM이 객체를 삭제하면 원본과 유일 백업이 동시 소실될 수 있었다.
- soft delete를 7일(GCS 최소값)로 활성화해 삭제 객체 복구 창을 확보했다.
  SLM 정상 삭제는 그대로 성공하고 soft-deleted 사본만 뒤에 남으므로 증분
  구조와 충돌하지 않는다. retention lock은 SLM 정리를 막으므로 미사용.

## 2026-07-14: WIF pusher SA를 승인 ref로 제한 (#175)

- Codex adversarial review high finding. gar_pusher/application_pusher SA의
  principalSet이 repository만 검사해 임의 브랜치 workflow도 가장 가능했다
  (공급망 위험 — 악성 브랜치가 dev GAR 이미지 덮어쓰기).
- bootstrap WIF provider에 `repository_ref`(repo@ref) 조합 attribute를
  추가하고, 두 pusher principalSet을 승인 ref(기본 refs/heads/main)로
  좁혔다. terraform-ci(read-only)는 대상 외.
- 앱 저장소 실제 배포 ref는 협의 필요 — 기본값 main으로 시작, 태그 릴리스
  등은 당시 변수로 조정하도록 남겼다. 이후 #187에서 application 권한은
  `application_release_workflow_ref`로 확정했다.

## 2026-07-14: KPO batch용 Spot node pool (#173)

- batch-spot pool을 신설했다(#105 후속 ②): spot=true, e2-standard-2,
  autoscaling min 0/max 2 — 평시 노드 0대(비용 0), toleration 있는 KPO만
  scale-from-zero로 수용. taint(workload=batch-spot:NoSchedule)로 일반
  워크로드 유입 차단.
- 부트 디스크는 pd-standard(#98 SSD quota 교훈). DaemonSet
  (filebeat/node-exporter)에 toleration을 부여해 Spot 노드의 로그·지표
  수집 공백을 방지했다(#105에서 명시한 함정).
- KPO pod의 nodeSelector/toleration 전환은 앱 저장소 소관 — 전환 전까지
  KPO는 기존 airflow pool에서 동작(무해). Spot 중단 내성은 KPO retry 담당.

## 2026-07-14: GKE node pool 운영 최적화 1차 (#106)

- 실측(설치 직후 스냅샷) 기반 1차 조정: ① airflow pool max 1→2 — KPO
  배치 피크의 escape valve(평시 비용 불변, KPO는 일회성이라 scale-down
  회수됨) ② Prometheus(실측 508Mi)/Grafana(315Mi)에 requests/limits 부여
  — 미설정 상태는 스케줄러·CA 판단을 왜곡(#105 배치 문제의 원인 중 하나).
- machine type은 변경하지 않음(노드 재생성 회피 — rollback 기준: min/max와
  requests는 in-place 되돌림 가능).
- 한계 명시: 모니터링이 갓 설치되어 데이터 창이 짧다 — Prometheus 7일
  축적 후(7/21 전후) 피크 데이터로 2차 점검을 조건으로 남김.

## 2026-07-13: 플랫폼 stateful dev-default 고정 (#170)

- #105 후속 ①. Prometheus/Grafana/Vault에 dev-default nodeSelector를
  적용해 "stateful 명시 고정" 원칙을 완성했다(ES/Kibana는 기적용).
- 계기: taint 부재로 Prometheus(30Gi PVC)가 작은 airflow 노드에 배치돼
  메모리 압박에 기여하던 실측 문제.

## 2026-07-13: Autoresearch 앱 이미지 GAR 배포 경계 추가 (#157)

- Autoresearch 애플리케이션 이미지 release를 위해 전용 SA
  `autoresearch-dev-app-pusher`를 추가했다. 기존 Airflow용
  `autoresearch-dev-gar-pusher`는 변경하지 않는다.
- 새 SA 가장은 `SKYAHO/Autoresearch` principalSet에만 허용하고,
  `autoresearch-dev-docker` repository 단위 `roles/artifactregistry.writer`만
  부여했다. 프로젝트 수준 권한과 service account key는 사용하지 않는다.
- bootstrap 로컬 tfvars의 WIF 허용 목록에 Autoresearch를 추가한 후 dev root를
  적용하는 2단 순서와 회귀 방지 절차를 문서화했다.
- 서비스 계정과 IAM binding은 직접 비용이 없고 새 리전 리소스도 만들지 않는다.
  롤백은 앱 release 비활성화 → app pusher SA/IAM 제거 → bootstrap 허용 목록 제거
  순서다.

## 2026-07-13: Grafana Google OAuth 로그인 (#155)

- 로그인을 admin 비밀번호 공유에서 Google OAuth(팀원 개인 계정)로 전환했다.
  client id/secret은 운영자 주입 Secret(grafana-google-oauth)의 env 참조로만
  구성 — values/Git/state에 값 없음.
- gmail은 도메인 제한이 불가능하므로 allow_sign_up=false + 계정 사전 생성
  방식으로 allowlist를 구현했다. 팀원 이메일은 Git/문서/이슈에 기록하지
  않고 Grafana DB에만 존재한다(이메일 비노출 요구).
- admin 계정은 비상용으로 유지. redirect URI는 port-forward 주소
  (localhost:3000) — 내부 전용 접근 원칙 유지.

## 2026-07-13: Terraform drift 감지 자동화 (#153)

- 매일 1회 dev root plan -detailed-exitcode로 코드-인프라 불일치를 감지해
  [DRIFT] 이슈를 자동 생성하는 workflow를 추가했다(#79 미적용 스택 재발
  방지). CI SA의 기존 viewer 권한만 사용 — apply 권한 부여 없음.
- 자동 apply는 도입하지 않기로 결정했다: 권한 폭발(viewer→editor급),
  admin root의 구조적 CI 불가(master 접근), apply 시점 사람 검증의 가치
  (#116/#122/#98 인시던트 실증). 2단계(Environment approval 반자동)는
  별도 설계 후 검토한다.

## 2026-07-13: private googleapis DNS zone과 vault egress 443 축소 (#138)

- PR #135 리뷰 제안 후속. VPC private zone `googleapis.com.`으로 Google API
  해석을 private.googleapis.com 고정 VIP(199.36.153.8/30)로 유도하고, vault
  namespace의 egress 443을 `0.0.0.0/0`에서 이 대역 + services CIDR
  (kubernetes.default VIP)로 축소했다.
- 당초 3개 namespace 일괄 축소를 검토했으나 argocd(GitHub)와
  airflow(OpenRouter, run.app)는 외부 endpoint 의존이 확인되어 유지하고
  사유를 코드 주석과 문서에 남겼다.
- zone은 googleapis.com만 override하므로 pkg.dev(이미지 pull), run.app,
  metadata 경로는 영향이 없다. 롤백은 두 변경 모두 in-place이며 zone 제거
  시 TTL 300s 내 공개 IP 해석으로 복귀한다.

## 2026-07-13: Vault 초기 구성 절차 확립 (#136)

- 3단계로 audit device(file), Kubernetes auth method(chart authDelegator
  기반), KV v2 engine, 최소 권한 policy(demo-read)와 시범 secret 절차를
  runbook에 확립하고 실행했다. Vault 내부 리소스는 설계 원칙대로 Terraform이
  아닌 운영자 절차로 관리한다.
- root token은 초기 구성 완료 후 revoke한다. auth method 구성 전에 revoke하면
  관리 접근이 recovery key generate-root에만 의존하게 되므로, 2단계 runbook의
  "init 직후 audit" 문구를 이 순서로 보정했다.
- Kubernetes auth 검증은 root token 없이 KSA JWT 로그인 → 시범 secret 읽기로
  수행한다. consumer는 NetworkPolicy상 vault namespace 내부로 한정되며, 타
  namespace 연동(ingress 허용 또는 ESO)은 별도 설계로 남긴다.

## 2026-07-13: Feast Online Store Redis Cluster 설계 정정 (#129, apply 대기)

- dev Online Store는 `REDIS_SHARED_CORE_NANO` primary shard 2개, replica 0개의
  Memorystore for Redis Cluster로 구성한다. zonal GKE와 같은
  `asia-northeast3-a`의 `SINGLE_ZONE`에 배치하며 nano node에는 SLA가 없다.
- 기존 dev VPC에 전용 PSC `/29` subnet과 `gcp-memorystore-redis` Service
  Connection Policy를 만들며 public endpoint를 생성하지 않는다.
- IAM 인증과 TLS를 활성화한다. app GSA에는 resource name 조건부
  `roles/redis.dbConnectionUser`를 부여하고, IAM token은 런타임에만 발급한다.
  TLS CA bundle만 Secret Manager에 저장한다.
- NetworkPolicy는 PSC discovery 6379와 data node 11000-13047을 허용한다.
- 동일 hash tag key의 `MGET` 성공과 다른 slot의 `CROSSSLOT`을 GKE 내부에서
  검증하며 실제 Feature key schema는 앱 저장소 후속 작업으로 분리한다.
- 2026-07-11의 Basic 단일 Redis 초안은 apply되지 않았고 이 결정으로 대체한다.

## 2026-07-13: 운영 workload node pool 전략 (#105)

- 실측에서 배치 문제를 발견했다: taint 부재로 Prometheus 본체(30Gi PVC)가
  작은 airflow 노드에 앉아 메모리 압박에 기여 중. 원칙을 "stateful은 명시
  고정, stateless는 자유"로 정리했다.
- 전용 pool 결론: monitoring/mlflow/argocd 불필요, ES는 트리거 정의
  (headroom<3Gi 또는 확장 시), 신규 후보는 batch Spot pool뿐(#104).
- taint 기준: 2-pool 체제에서는 nodeSelector로 충분, 전용 pool부터 taint
  필수 + DaemonSet toleration 동반.
- 후속: Prometheus/Grafana/Vault의 dev-default nodeSelector 적용(소규모),
  Spot pool 신설, ES 전용 pool(트리거 시).

## 2026-07-13: GKE autoscaling 전략 검토 (#104)

- 실측: dev-default는 CA min1/max2로 이미 활성, airflow-dev는 min=max=1
  고정(의도), NAP/VPA 비활성.
- 결론: dev는 현행 유지. NAP 보류(워크로드 프로필 2종 고정 + 비용 예측성),
  **Karpenter 비권장 확정**(GKE 공식 지원 없음, CA/NAP가 네이티브 대체).
- 핵심 통찰: PVC(RWO) stateful pod들 때문에 scale-down이 점착적 — 확장은
  사실상 반영구 증설로 취급. 다음 개선은 autoscaling이 아니라 #105(Spot
  batch pool, ES 전용 pool 트리거)에 있다.

## 2026-07-13: Kibana/ELK 운영 runbook (#103) — ELK 트랙 완결

- #98~#102 검증에서 실행한 명령 기준으로 KIBANA_OPERATIONS_RUNBOOK을
  작성했다: 접속/data view, KQL 검색(Airflow 실패·앱 에러), K8s 이벤트는
  수집 범위 밖(kubectl/Grafana) 명시, 정기 점검(ILM delete phase·SLM
  last_success·PVC), 장애 1차 표(트랙 인시던트들 반영), 업그레이드 주의
  (operator 먼저 + kubernetes_manifest 수렴 재확인), 폐기 순서.
- 팀원용 Kibana 접속 절을 TEAM_OPERATIONS_RUNBOOK에 추가했다(상위 문서
  동시 점검 원칙).
- 이로써 ELK 트랙(#96~#103)이 완결됐다.

## 2026-07-13: ES GCS snapshot 백업 (#102)

- dev root에 snapshot 전용 bucket(es-snapshots)과 GSA/WI(키 없음)를
  추가했다. 권한은 bucket 단위 objectAdmin + legacyBucketReader만.
- ES pod를 전용 KSA(elasticsearch)로 전환하고 metadata egress를 열어
  repository-gcs가 ADC(WI)로 인증한다. SLM 일 1회(03:30 KST)·expire 7d.
- #96 spec의 "bucket lifecycle로 정리" 문구를 정정했다 — ES snapshot은
  증분(세그먼트 공유) 구조라 age 기반 객체 삭제가 최신 snapshot을
  손상시킨다. 정리는 SLM retention만 사용한다.

## 2026-07-13: ES ILM/retention 정책 (#101)

- filebeat 기본 ILM(rollover 30d/50gb, 삭제 없음)을 hot rollover 1d/5gb +
  delete 7d로 교체했다(운영자 절차 — ES 내부 리소스는 Terraform 밖 원칙).
  PVC 30Gi 고정에서 무한 보관을 차단하는 비용 방지 장치다.
- filebeat 템플릿 replicas를 0으로 교체(Beat config setup.template) —
  기본값 1이 single-node에서 unassigned replica를 만들어 cluster가
  yellow였던 것을 green으로 복구했다(#96/#98 예고 지점 실측).
- dev/운영 보관 분리 기준: 운영 전환 시 delete min_age만 상향.

## 2026-07-13: Filebeat 로그 수집 (#100)

- Beat CR(Filebeat DaemonSet)로 airflow·autoresearch namespace 컨테이너
  로그만 수집한다(autodiscover allowlist). 시스템/플랫폼 로그는 Cloud
  Logging 담당 — 중복 수집 방지 기준을 문서화했다.
- 전용 SA + 읽기 전용 ClusterRole(autodiscover 최소 권한), ES 연결은
  services CIDR 9200 egress 추가로 허용(pre-DNAT VIP — #122 교훈).
- hostPath read의 PSS baseline 위반은 audit/warn(비강제)로 수용하고
  근거를 README에 기록했다(#96에서 확인 예약된 항목의 결론).

## 2026-07-13: Kibana 내부 접근 구성 (#99)

- Kibana CR(1 replica, ES와 동일 스택 버전, elasticsearchRef 연결)을
  elastic-k8s root에 추가했다. ClusterIP + port-forward 전용, LB/Ingress
  없음, TLS는 ECK 기본(self-signed).
- 노드 대역 → 5601 ingress는 #97 NetworkPolicy에 이미 선언되어 있다.
  elastic 사용자 비밀번호는 Secret 회수 절차만 사용(Git/문서 금지).

## 2026-07-13: Elasticsearch 최소 클러스터 (#98)

- elastic-k8s root에 Elasticsearch CR `autoresearch`(9.2.0, single-node,
  heap 1G, request 2Gi/limit 3Gi, PVC 30Gi standard-rwo)를 추가했다.
- nodeSelector로 dev-default pool에 고정해 airflow-dev pool 압박을 방지했다.
  전용 node pool은 불필요로 결론(실측 여유 기준, headroom 3Gi 미만 시
  #105에서 재검토).
- `node.store.allow_mmap: false`로 vm.max_map_count sysctl(privileged
  initContainer) 요구를 회피해 PSS baseline을 유지했다.
- TLS/인증은 ECK 기본 유지. index 기본 replicas 0 template은 #101에서 적용.

## 2026-07-13: ES PVC 스토리지 클래스 정정 — SSD quota 인시던트 (#98)

- 첫 apply에서 PVC provisioning이 `SSD_TOTAL_GB` quota 초과(리전 250GB,
  실측 223 사용)로 실패했다. `standard-rwo`(pd-balanced)가 SSD quota를
  소비하며, 노드 부트 디스크와 기존 PVC로 이미 한도 근처였다.
- ES data PVC를 `standard`(pd-standard, HDD)로 변경했다 — dev 로그
  워크로드에 IOPS 충분, 비용 절감. WaitForFirstConsumer 덕에 PD 생성 전
  단계에서 멈춰 부작용 없이 정정했다.
- 교훈: PVC 추가 시 스토리지 클래스의 quota 종류(SSD vs HDD)와 리전
  사용량(`gcloud compute regions describe`)을 사전 확인한다.

## 2026-07-13: ECK operator 설치 (#97)

- admin root `elastic-k8s`를 신설해 chart `eck-operator` 3.4.1을 설치했다.
  `managedNamespaces: [elastic]`으로 operator 감시 범위를 최소화했다.
- validating webhook은 포트를 10250으로 옮겨 private GKE 기본 master→node
  방화벽을 재사용했다(monitoring-k8s의 prometheusOperator.internalPort 선례
  — 별도 firewall 불필요).
- 이슈 본문의 elastic-system 대신 #96 설계대로 단일 namespace `elastic`을
  사용한다. CRD는 helm uninstall에도 남는다(삭제 시 CR 연쇄 삭제·데이터
  유실 — README 롤백 절 참조).

## 2026-07-13: 운영형 ELK 아키텍처 설계 (#96)

- ECK operator 기반으로 확정했다. admin root `elastic-k8s`(신설 예정)에서
  operator는 helm_release, ES/Kibana는 CR(kubernetes_manifest)로 관리한다.
- Cloud Logging(기본 안전망)과 ELK(앱·Airflow 로그 검색/분석)를 병행하고
  서로 대체하지 않는다 — #77 metric 분리와 동일 원칙.
- dev 최소 구성: single-node ES(heap 1G, PVC 30Gi), Kibana ClusterIP +
  port-forward. 노드 실측 여유(~8.8GB) 기준으로 신규 node pool 없이
  수용한다(운영 전환 시 #105에서 재검토). 월 $5 미만.
- ECK 기본 TLS/인증을 처음부터 유지한다(Vault와 달리 operator가 인증서를
  자동 관리하므로 비용 없음). ILM 7일, GCS snapshot 일 1회·7일 보관.
- 후속 이슈(#97~#103) 입력값을 spec에 정리했다.

## 2026-07-13: Argo Rollouts 운영 runbook (#90)

- #89 실측 명령 기준으로 `docs/ROLLOUTS_OPERATIONS_RUNBOOK.md`를 작성했다:
  상태 확인, 수동 promote(1단계 표준 — Grafana 확인 후), abort/rollback
  구분(Git revert 원칙), 실패 확인 순서, ArgoCD 연계 지점, 재현 manifest.

## 2026-07-13: Argo Rollouts 샘플 검증 (#89)

- 샘플 canary(2 replica, 50% → pause → 100%)로 배포→canary 정지→promote→
  abort→undo 전 흐름을 실측 검증하고 샘플을 폐기했다.
- 핵심 교훈: abort는 트래픽만 stable로 되돌리고 Degraded로 남는다 — 복구는
  spec을 되돌리는 것(ArgoCD 연결 후에는 Git revert가 원칙, CLI undo는
  OutOfSync 유발). pause 무기한 특성상 적용 앱은 N-1 호환이 전제다.
- metric 연동은 #87 결정대로 2단계 후속으로 유지한다(1단계 수동 promote).

## 2026-07-13: Argo Rollouts controller 설치 (#88)

- admin root `argo-rollouts-k8s`를 신설해 chart `argo-rollouts` 2.41.0을
  설치했다(dashboard 미설치 — kubectl plugin 운영). controller는 GCP API를
  쓰지 않아 NetworkPolicy egress가 DNS/K8s API로만 열린다(metadata·
  googleapis 규칙 없음 — vault-k8s보다 좁은 경계).
- RBAC은 chart upstream 기본 ClusterRole(전환 실행에 필요한 리소스 한정)을
  사용하고 근거를 root README에 기록했다.
- #87 spec의 "앱 배포 전 설치 금지" 문구는 기존 이슈 시리즈(#88~#90)와
  충돌해 "설치·샘플 검증 선행, 실 적용은 앱 배포 이슈"로 정정했다.

## 2026-07-13: Argo Rollouts 적용 범위 설계 (#87)

- 점진 배포 적용 대상을 Autoresearch 앱 API(stateless Deployment) 하나로
  한정했다. Airflow(stateful), batch pod(일회성), 플랫폼 컴포넌트, Cloud Run
  proxy(자체 traffic split)는 제외한다.
- Blue-Green은 dev 최소 비용 원칙과 충돌해 제외하고, 트래픽 라우터 없는
  replica-weight canary를 채택했다. 1단계는 수동 promote(Grafana 확인),
  metric 기반 자동 판단(AnalysisTemplate + Prometheus)은 2단계로 미뤘다.
- 책임 경계를 확정했다: ArgoCD는 Rollout manifest sync, Rollouts controller는
  전환 실행, promote/abort는 운영자, controller 설치는 Terraform admin root.
- controller는 앱 첫 배포 이슈와 같은 마일스톤에 설치한다(선제 설치 금지).

## 2026-07-13: 모니터링 스택 apply 완결 (#79 reopen)

- Grafana UI 접속 불가 확인 중 monitoring-k8s root가 apply된 적이 없음을
  발견했다(namespace 부재, state resources 0 — 7/9 시도 흔적만). 코드·
  runbook은 merge됐지만 스택은 미설치 상태였다.
- PVC(Prometheus 30Gi, Grafana 10Gi)에 `standard`(pd-standard)를 명시했다
  — 기본 standard-rwo였다면 SSD quota(#98과 동일)에 막혔을 것을 사전 차단.
- 교훈: apply·실검증까지가 이슈 완료 기준이라는 원칙을 재확인 — "코드
  merge = 완료"로 잘못 닫힌 이슈가 없는지 트랙 완료 시점에 state를 함께
  점검한다.

## 2026-07-12: GitHub Actions GAR push WIF 확장 (#121)

- Issue #121, PR #128(작성 Noah-JuYong)에서 Autoresearch-airflow 저장소
  GitHub Actions가 SA key 없이 WIF로 Artifact Registry에 이미지를 push하는
  경로를 추가했다.
- bootstrap WIF provider `attribute_condition`을 단일 리포 equality에서
  허용 목록(`allowed_github_repositories`) 멤버십으로 확장했다. 코드 default는
  infra 리포만이고, airflow 허용은 bootstrap 로컬 tfvars로 opt-in한다.
- dev root에 push 전용 SA `autoresearch-dev-gar-pusher`를 추가했다. 가장은
  Autoresearch-airflow 리포 principalSet만, 권한은 `autoresearch-dev-docker`
  repository 단위 `roles/artifactregistry.writer`만 부여했다(최소 권한).
- 토큰 발급(provider 조건)과 SA 가장(SA별 principalSet 바인딩)의 2단 경계로,
  airflow 리포가 토큰을 받아도 `terraform-ci` SA는 가장할 수 없다.
- bootstrap을 tfvars 없이 apply하면 airflow 허용이 default로 회귀하는 footgun이
  있어, 운영 값을 bootstrap 로컬 `terraform.tfvars`(비커밋)에 고정하고
  `TERRAFORM_BOOTSTRAP.md`에 주의를 명시했다(#130).
- 기존 Cloud Build push 경로(#32)와 병존한다. GitHub Actions 경로 end-to-end
  검증 후 정리 여부를 별도 이슈로 결정한다.

## 2026-07-12: HashiCorp Vault dev 도입 (1·2단계)

- 실무 학습 목적으로 Vault를 dev GKE에 도입했다. 기존 GCP Secret Manager는
  대체하지 않고 병존하며, TLS 활성화 전까지 Vault에는 학습·검증용 값만
  저장한다. 설계: `docs/superpowers/specs/2026-07-12-vault-dev-design.md`.
- 1단계(#132, dev root `vault.tf`): KMS keyring/key(`vault-unseal`,
  rotation 90d, prevent_destroy), 전용 GSA, `vault/vault` KSA WI 바인딩.
  gcpckms seal 요구 권한이 사전 정의 role에 없어(`cloudkms.cryptoKeys.get`
  누락) custom role을 key 단위로 바인딩했다. `roles/viewer`에 KMS
  getIamPolicy가 포함됨을 실측 확인해 CI plan refresh 문제가 없음을 검증했다.
- 2단계(#134, admin root `vault-k8s`): single-node integrated Raft +
  gcpckms auto-unseal, ClusterIP + port-forward 전용, deny-by-default
  NetworkPolicy(#116/#122/#126 교훈 반영 — services CIDR DNS VIP, metadata
  987/988). 운영 절차는 `docs/VAULT_OPERATIONS_RUNBOOK.md`.
- KMS rotation은 version 추가라 unseal에 무해하지만, 이전 key version
  disable/destroy는 Raft 데이터 복호화를 영구 불능으로 만든다 — 폐기 순서
  (release → PVC → key)를 runbook에 명시했다.

## 2026-07-10: egress 규칙 service VIP 대응 (#122)

- #116 enforcement 활성화 직후 selector 기반 egress DNS 허용 규칙이 동작하지
  않아 airflow/argocd namespace의 DNS가 차단되는 인시던트가 발생했다
  (Airflow 약 2시간 Init 정체, 완화로 egress 정책 임시 삭제).
- 격리 실험으로 원인을 확정했다: 이 클러스터의 Calico dataplane은 egress를
  DNAT 이전(service VIP 기준)에 평가하므로 namespaceSelector/podSelector가
  VIP 경유 트래픽에 매칭되지 않는다. `ipBlock(services CIDR)` 규칙은 동작한다.
- 두 admin root의 egress에 services CIDR(`cluster_services_cidr`,
  기본 172.16.128.0/24) ipBlock 규칙을 추가했다 — airflow: 53/5432,
  argocd: 53/6379/8081. kubernetes API VIP(443)는 기존 0.0.0.0/0:443이 커버한다.
- 기존 selector 기반 규칙은 post-DNAT 평가 dataplane(예: Dataplane V2)으로
  바뀌는 경우를 대비해 유지한다.
- 교훈: NetworkPolicy는 선언 검증만으로 부족하며, enforcement 활성화 시
  실제 트래픽 검증(차단·허용 양방향)을 반드시 수행한다.

## 2026-07-10: 운영 모니터링 설계

- Issue #77에서 Prometheus/Grafana 운영 모니터링 기준을 문서화했다.
- 실제 설치 전 설계 결정으로, `kube-prometheus-stack`을 우선 검토 대상으로 둔다.
- Grafana는 외부 공개하지 않고 Bastion 또는 `kubectl port-forward` 기반 내부 접근을
  기본으로 한다.
- dev 기준 Prometheus retention은 7일, PVC는 30Gi에서 시작하고 사용량에 따라 조정한다.
- Cloud Monitoring은 GCP managed resource 기본 관측, Prometheus/Grafana는
  Kubernetes와 application metric dashboard 담당으로 분리한다.

## 2026-07-10: monitoring Kubernetes admin root

- Issue #78에서 Prometheus/Grafana 설치 기반을 `terraform/admin/monitoring-k8s`로
  분리했다.
- dev root는 GCP 리소스, monitoring admin root는 Kubernetes namespace와 Helm values
  경계를 담당한다.
- Issue #79에서 `kube-prometheus-stack` Helm release를 추가했다.
- Grafana admin credential은 Terraform state에 저장하지 않고 기존 Kubernetes
  Secret 이름과 key만 Helm values로 참조한다.
- Issue #80에서 Grafana UI를 `ClusterIP` + `kubectl port-forward` 내부 접근으로
  정리하고, monitoring namespace의 port-forward 전용 최소 RBAC를 추가했다.
- Issue #81에서 GKE node, Pod CPU/memory, PVC, Airflow, 앱/배치 상태를 Grafana로
  확인하는 운영 runbook을 추가했다.

## 2026-07-10: ArgoCD GitOps 운영 설계

- Issue #82에서 Terraform과 ArgoCD의 책임 경계를 정리했다.
- 초기 ArgoCD sync 정책은 manual sync로 시작하고, prune/self-heal은 안정화 후
  Application별로 검토한다.
- Secret payload는 Git과 Terraform state에 저장하지 않고 Secret Manager 또는
  운영자 주입 경로를 사용한다.
- Issue #83에서 ArgoCD 설치 기반을 `terraform/admin/argocd-k8s`로 분리하고
  `argocd` namespace와 Helm values scaffold 위치를 정했다.

## 2026-07-10: ArgoCD 최소 설치

- Issue #84에서 argo-cd Helm chart `10.1.3`(ArgoCD v3.4.5)을
  `terraform/admin/argocd-k8s`에 pin해 설치했다.
- server Service는 `ClusterIP`로 유지하고 UI는 `kubectl port-forward` 내부
  접근만 허용한다. 외부 공개 리소스(LoadBalancer/Ingress)는 만들지 않는다.
- dex(SSO), notifications, applicationSet controller는 최소 설치 원칙으로
  비활성화하고 사용 시점의 이슈에서 활성화한다.
- 초기 admin 비밀번호는 chart가 생성하는 `argocd-initial-admin-secret`으로
  회수한 뒤 변경하고 secret을 삭제한다. payload는 Git/Terraform state에
  저장하지 않는다.

## 2026-07-10: NetworkPolicy enforcement와 argocd 네트워크 경계

- Issue #116(코드 리뷰 finding 반영)에서 dev GKE에 Calico NetworkPolicy
  enforcement를 활성화했다. 그 이전에는 enforcement가 꺼져 있어 #32/#48의
  airflow NetworkPolicy가 선언만 되고 강제되지 않았음을 확인했다.
- enforcement 활성화로 기존 airflow egress 정책이 실제 동작하게 되므로,
  same-namespace egress 허용을 추가해 in-cluster PostgreSQL(5432)/redis
  통신 차단을 방지했다.
- argocd namespace에 deny-by-default ingress/egress NetworkPolicy를 추가했다.
  `kubectl port-forward` 트래픽은 노드 IP에서 출발하므로 dev subnet →
  argocd-server 8080 ingress를 허용해 UI 접근을 유지한다.
- enforcement 활성화 apply는 노드풀 롤링 재생성을 수반한다(dev 단절 허용).
  monitoring namespace는 NetworkPolicy가 없어 영향이 없고, 경계 추가는 별도
  이슈로 검토한다.

## 2026-07-10: ArgoCD applicationSet 비활성 방식 정정

- Issue #115: #84에서 사용한 `applicationSet.enabled: false`는 argo-cd chart
  8.0부터 제거된 키로, chart `10.1.3`에서 무시되어 applicationset-controller가
  기동되고 있었다(apply 후 검증에서 발견).
- chart가 enabled 플래그를 제공하지 않으므로(core 컴포넌트 승격)
  `applicationSet.replicas: 0`으로 중지해 원래 문서화한 최소 설치 상태를
  달성했다. ApplicationSet CR을 사용하는 시점에 replicas를 복원한다.
- dex/notifications의 `enabled: false`는 chart에서 지원되는 키로 정상 동작
  중임을 함께 확인했다.

## 2026-07-10: ArgoCD AppProject/Application 샘플

- Issue #85에서 AppProject `autoresearch-dev`와 샘플 Application
  `sample-guestbook`(공개 repo guestbook → `argocd-sample` namespace)을
  추가했다.
- AppProject는 최소 허용 원칙으로 샘플 repo와 `argocd-sample` destination만
  열었다. 실제 repo(`SKYAHO/Autoresearch-airflow` 등)는 해당 Application을
  만드는 이슈에서 추가한다.
- sync 정책은 manual만 사용한다(auto-sync/prune/self-heal 미사용 —
  GITOPS_STRATEGY 초기 원칙). cluster-wide 리소스는 AppProject 기본 거부를
  유지한다.
- 샘플은 sync/diff/rollback 흐름 검증용이며, 실제 repo 연결 시 제거한다.
- Issue #86에서 접속, 상태 확인, diff/sync/rollback, credential 주입, 장애
  대응 절차를 `docs/ARGOCD_OPERATIONS_RUNBOOK.md`로 문서화했다. 절차 명령은
  #85 검증에서 실행해 확인한 것을 기준으로 한다.

## 2026-07-09: 문서 구조 정리

- Issue #71에서 팀원 접근 runbook, Terraform 운영 문서, 변경 이력을 분리했다.
- 완료된 spec/plan 상세 문서는 이 파일의 요약 이력으로 압축했다.

## 2026-07-08: Airflow 운영 경계

- Issue #32 계열에서 Airflow용 GCP 리소스와 Kubernetes 경계를 분리했다.
- dev root는 Airflow GSA, Cloud SQL metadata DB, DAG/log bucket, Secret Manager,
  BigQuery/GCS IAM을 관리한다.
- `terraform/admin/airflow-k8s`는 namespace, KSA, RBAC, quota, limit range,
  network policy를 별도 state로 관리한다.
- Airflow batch workload는 전용 GSA
  `autoresearch-dev-airflow-batch@ar-infra-501607.iam.gserviceaccount.com`로
  분리했다.

## 2026-07-08: Bastion host

- Issue #47, PR #50에서 외부 IP 없는 IAP 전용 bastion을 도입했다.
- 목적은 Airflow UI 등 VPC 내부 서비스 접속 터널이다.
- kubectl은 Bastion이 아니라 GKE DNS endpoint를 기본 경로로 사용한다.
- 미사용 시 `bastion_enabled=false`로 제거할 수 있다.

## 2026-07-08: Airflow 내부 DNS와 ILB

- Issue #48, PR #51에서 Airflow UI용 내부 IP와 private DNS zone을 구성했다.
- `airflow.dev.autoresearch.internal`은 VPC 내부에서만 해석된다.
- UI 접속 기본 경로는 Bastion `-L 8080` 포트 포워딩 후
  `http://localhost:8080`이다.
- Google OAuth redirect URI 제약으로 `.internal` 직접 로그인은 사용하지 않는다.

## 2026-07-08: GKE DNS endpoint

- Issue #45, PR #46에서 GKE DNS 기반 control plane endpoint를 기본 접근 경로로
  정리했다.
- 팀원 IP 등록 없이 `roles/container.viewer`의 `container.clusters.connect`로
  kubeconfig를 받을 수 있다.
- `master_authorized_networks`는 IP endpoint 예비 경로로만 남긴다.

## 2026-07-08: GKE worker node sizing

- dev 기본 node pool은 `e2-standard-4`, Airflow node pool은 `e2-standard-2`로
  정리했다.
- GKE control plane은 관리형이므로 사용자가 마스터 노드 CPU/RAM을 직접 지정하지
  않는다.

## 2026-07-08: dev state drift cleanup

- Issue #39에서 dev state에 남아 있던 legacy node pool, legacy Airflow batch WI
  binding, 불필요한 Cloud Build 기본 compute SA 권한, 추가 master authorized
  network CIDR을 정리했다.
- 유지 근거가 없는 리소스는 state만 숨기지 않고 실제 리소스까지 정리한다는 원칙을
  확인했다.

## 2026-07-07: dev proxy Cloud Run

- Issue #27, PR #30에서 `autoresearch-dev-proxy` Cloud Run 서비스를 정의했다.
- min instances 0, internal ingress, invoker IAM 기반으로 시작했다.
- 이미지 재배포는 `:latest` 재사용이 아니라 새 tag 또는 digest로 `proxy_image`를
  바꾸고 apply하는 방식을 표준으로 삼았다.
- Issue #73, PR #74에서 Airflow batch GSA
  `autoresearch-dev-airflow-batch@ar-infra-501607.iam.gserviceaccount.com`에
  `autoresearch-dev-proxy` 서비스 단위 `roles/run.invoker`를 부여했다.

## 2026-07-06: GitHub Actions Terraform plan + OIDC

- Issue #6, PR #15에서 GitHub Actions PR plan을 구성했다.
- service account key 대신 GitHub OIDC + Workload Identity Federation을 사용한다.
- CI SA는 dev plan에 필요한 viewer/state 접근 중심으로 운영한다.
- bootstrap root는 state bucket, WIF pool/provider, CI SA를 1회성으로 관리한다.

## 2026-07-03: dev GKE 클러스터

- Issue #5, PR #14에서 dev GKE Standard zonal 클러스터를 구성했다.
- private nodes, VPC-native alias IP, 별도 node service account, Artifact
  Registry reader, logging/monitoring writer 권한을 적용했다.
- app Workload Identity는 `autoresearch/autoresearch-app` KSA와
  `autoresearch-dev-app` GSA 매핑으로 시작했다.
