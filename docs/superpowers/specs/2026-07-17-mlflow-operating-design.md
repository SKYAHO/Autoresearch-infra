# MLflow 운영 구조 설계 (#91)

> 작성: 2026-07-17 | 성격: 설계(문서만 — GCP 리소스 변경 없음)
> 목적: MLflow Tracking Server + Model Registry의 backend/artifact/배포/접근/권한 구조를
>       확정하고, 후속 구현(#92~#95) 범위를 분리한다.
> 배포 방식: **ArgoCD Application**(monitoring·argo-rollouts와 GitOps 일관).

## 역할 경계 (선결 정리)

MLflow는 두 저장소가 나눠 소유한다. 이 설계는 **인프라 저장소 범위**만 다룬다.

| 소유 | 저장소 | 범위 |
|---|---|---|
| 이미지·런타임 | `SKYAHO/Autoresearch`(앱) | MLflow 커스텀 이미지(v2.22.1 + PostgreSQL/GCS 패키지, UV, build-time deps). 설계: 앱 `docs/specs/2026-07-14-mlflow-deployment-strategy.md` |
| GCP 리소스·GKE 배포 경계 | `SKYAHO/Autoresearch-infra`(본 repo) | GCS artifact bucket, Cloud SQL DB/user, tracking server 배포, IAM/네트워크, runbook (#91~#95) |

인프라는 앱이 GAR에 push한 **커스텀 이미지를 참조해 배포만** 한다. 이미지 자체는 만들지 않는다.

## 결정 요약

| 항목 | 결정 | 근거 |
|---|---|---|
| 배포 방식 | **ArgoCD Application** (`deploy/mlflow` umbrella chart) | monitoring(#183)·argo-rollouts(#186) 이관과 GitOps 일관. infra repo **public**이라 ArgoCD 자격증명 불필요 |
| namespace 경계 | 신규 admin root **`mlflow-k8s`** (namespace + KSA(WI) + NetworkPolicy) | `autoresearch-k8s` 패턴. "Terraform=플랫폼 경계, ArgoCD=앱"(GITOPS_STRATEGY) |
| backend store | **기존 Cloud SQL `autoresearch-dev-pg` 재사용**, MLflow 전용 **DB + user** 신설 | 8회차 "DB 외부화" + Airflow/앱과 **schema/DB 분리**. 신규 인스턴스 비용 회피 |
| artifact store | **신규 GCS 버킷 1개**, MLflow **proxy 모드**(`--serve-artifacts`) | 9회차. 클라이언트는 GCS 직접 접근 없이 **MLflow 서버 경유** → GCS 자격 미노출 |
| 이미지 | 앱 저장소 커스텀 이미지(GAR) 참조 | 앱 spec 소유. 공식 이미지엔 PostgreSQL/GCS 패키지 없음(9회차) |
| UI 접근 | **내부 전용**(ClusterIP → 내부 ILB 또는 port-forward). **외부 노출 금지** | 보안 최우선. Grafana/ArgoCD 선례 |
| 인증/권한 | **MLflow 전용 GSA** + Workload Identity, GCS/SQL/Secret **최소 IAM** | GCS 인증은 MLflow 서버에만. SA key 없음 |
| sync 정책 | **manual**(초기) | GITOPS_STRATEGY 초기 원칙(auto-sync/prune off) |
| node pool | **dev-default**(전용 불필요) | node-pool-strategy: 소형 stateless + 외부 DB |

## 현재 상태 (실측)

- Cloud SQL `autoresearch-dev-pg`: PostgreSQL 15, **private IP only**(`ipv4_enabled=false`),
  기존 DB/user 1쌍(앱용). MLflow용 DB/user는 없음.
- ArgoCD `autoresearch-dev` AppProject: sourceRepos=infra repo, destinations=monitoring/
  argo-rollouts/kube-system, cluster-wide 리소스는 화이트리스트만. MLflow destination 없음.
- MLflow 관련 GCP 리소스·K8s 리소스 **미배포**(문서상 "MLflow 후속 미착수").
- 앱 저장소에 MLflow 이미지/런타임 spec 존재(#94 참조).

## 상세 설계

### 1) Backend store — Cloud SQL 전용 DB/user (#93)
- 기존 `autoresearch-dev-pg` 인스턴스에 **MLflow 전용 `google_sql_database`(`mlflow`) + `google_sql_user`(`mlflow`)** 추가. Airflow/앱과 **논리 분리**.
- 비밀번호는 `random_password` → **Secret Manager**에만 저장(state에 평문 금지는 sensitive로 관리). Git/PR/tfvars 노출 금지.
- MLflow 서버는 **private IP로 직접 연결**(`postgresql://mlflow:<pw>@<private-ip>/mlflow`). 기존 앱과 동일 경로라 Cloud SQL Auth Proxy 불필요.

### 2) Artifact store — GCS proxy 모드 (#92)
- 신규 버킷 `autoresearch-dev-mlflow-artifacts`: `uniform_bucket_level_access=true`,
  `public_access_prevention=enforced`, soft_delete(복구층), 라벨(purpose=mlflow-artifacts).
- MLflow **proxy 모드**: 서버가 `--serve-artifacts --artifacts-destination gs://.../`로 뜨고,
  클라이언트는 `mlflow-artifacts:` 스킴으로 **서버를 경유**한다. 클라이언트에 GCS 자격을 주지 않는다(9회차 원칙).

### 3) 배포 — ArgoCD Application + mlflow-k8s (#94)
- **`terraform/admin/mlflow-k8s`**(신규 admin root): namespace `mlflow` + KSA `mlflow`(WI 애노테이션) +
  deny-by-default NetworkPolicy. `autoresearch-k8s`와 동일 패턴, 별도 state.
- **`deploy/mlflow`**(umbrella chart): community MLflow chart를 dependency로 pin, values에서
  image=앱 GAR 이미지, backendStoreUri(secret 참조), artifactRoot=gs://, serviceAccountName=`mlflow`(WI).
- **`argocd-k8s`**: AppProject destination에 `mlflow` 추가 + Application `mlflow`(source `deploy/mlflow`,
  manual sync, `CreateNamespace=false` — namespace는 mlflow-k8s가 소유).
- 이미지 경로·chart 버전 pin은 #94에서 앱과 조율해 확정.

### 4) UI 접근
- **외부 노출 금지**. ClusterIP로 시작, 운영자는 port-forward, 팀 접근은 내부 ILB(dns.tf 선례) 검토.
- UI 인증(OAuth2-proxy 등)은 **후속**. 초기엔 내부 네트워크 접근 경계로만 보호(정보 민감도 낮은 dev 실험 메타데이터).

### 5) IAM·보안 (최소권한)
- **신규 GSA `autoresearch-dev-mlflow`** (앱 GSA와 분리 — GCS 자격을 MLflow에만).
- WI: `roles/iam.workloadIdentityUser` ← `...svc.id.goog[mlflow/mlflow]`.
- GCS: 아티팩트 버킷에 `roles/storage.objectAdmin` **+ `roles/storage.legacyBucketReader`**
  (**#204 교훈**: objectAdmin엔 `storage.buckets.get`가 없어 일부 GCS 클라이언트가 403 — 선반영).
- Cloud SQL: `roles/cloudsql.client`(연결) — private IP라 network는 NetworkPolicy로 제한.
- Secret Manager: MLflow DB secret에만 `roles/secretmanager.secretAccessor`(resource-level).
- **SA key 생성 금지**, DB creds는 Secret Manager만.

### 6) 네트워크
- `mlflow-k8s` NetworkPolicy egress(deny-by-default + 화이트리스트): Cloud SQL PSA CIDR(5432),
  GCS/Google API(443), GCE metadata·WI(169.254.169.254/252), DNS(kube-dns). ingress는 내부만.

## 후속 이슈 범위 분리 (#91 완료 조건)

| 이슈 | 범위 | 산출물 |
|---|---|---|
| **#92** | GCS artifact bucket | `storage.tf` 버킷 + IAM(objectAdmin+legacyBucketReader), 문서 |
| **#93** | Cloud SQL DB/user | `cloud_sql.tf` mlflow DB+user+password, `secret_manager.tf` secret+IAM |
| **#94** | tracking server 배포 | `admin/mlflow-k8s`(ns/KSA/NP) + `deploy/mlflow` chart + `argocd-k8s` Application. 앱 이미지 조율 |
| **#95** | 운영 runbook | `docs/MLFLOW_OPERATIONS_RUNBOOK.md`(접속·복구·백업·권한) |

권장 순서: **#92 → #93 → #94 → #95**(리소스 선행, 배포는 backend/artifact 준비 후).

## 보안 체크 (요약)
- 외부 노출 0(내부 전용 UI). 최소 IAM(버킷/secret resource-level, 전용 GSA).
- 시크릿은 Secret Manager만·WI 주입(키 없음). GCS 자격은 MLflow 서버에만(proxy 모드).
- feast IAM 교훈(`buckets.get`) 선반영. state/tfvars/PR 시크릿 금지.

## 비용
- Cloud SQL **재사용**(신규 인스턴스 0). GCS 버킷 1개(dev 규모 소액). pod 1개 소형(dev-default, 전용 노드 0).
- 증분 비용 최소. 리전 `asia-northeast3` 유지.

## 미결정 (TBD — 후속에서 확정)
- MLflow UI 인증 방식(내부 접근만 vs OAuth2-proxy) — 초기 내부 전용, 인증은 후속.
- `deploy/mlflow` community chart 및 버전 pin — #94에서 앱 이미지와 함께 확정.
- 앱 GAR 이미지 경로/태그 규약 — #94에서 앱 팀과 조율.
