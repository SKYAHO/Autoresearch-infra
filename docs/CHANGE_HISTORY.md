# 인프라 변경 이력 요약

완료된 설계 spec과 구현 plan의 핵심 결정만 보존한다. 현재 운영 절차는
`TEAM_OPERATIONS_RUNBOOK.md`와 `TERRAFORM_DEV.md`를 우선한다.

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

## 2026-07-03: dev GKE 클러스터

- Issue #5, PR #14에서 dev GKE Standard zonal 클러스터를 구성했다.
- private nodes, VPC-native alias IP, 별도 node service account, Artifact
  Registry reader, logging/monitoring writer 권한을 적용했다.
- app Workload Identity는 `autoresearch/autoresearch-app` KSA와
  `autoresearch-dev-app` GSA 매핑으로 시작했다.

## 2026-07-06: GitHub Actions Terraform plan + OIDC

- Issue #6, PR #15에서 GitHub Actions PR plan을 구성했다.
- service account key 대신 GitHub OIDC + Workload Identity Federation을 사용한다.
- CI SA는 dev plan에 필요한 viewer/state 접근 중심으로 운영한다.
- bootstrap root는 state bucket, WIF pool/provider, CI SA를 1회성으로 관리한다.

## 2026-07-07: dev proxy Cloud Run

- Issue #27, PR #30에서 `autoresearch-dev-proxy` Cloud Run 서비스를 정의했다.
- min instances 0, internal ingress, invoker IAM 기반으로 시작했다.
- 이미지 재배포는 `:latest` 재사용이 아니라 새 tag 또는 digest로 `proxy_image`를
  바꾸고 apply하는 방식을 표준으로 삼았다.
- Issue #73, PR #74에서 Airflow batch GSA
  `autoresearch-dev-airflow-batch@ar-infra-501607.iam.gserviceaccount.com`에
  `autoresearch-dev-proxy` 서비스 단위 `roles/run.invoker`를 부여했다.

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

## 2026-07-09: 문서 구조 정리

- Issue #71에서 팀원 접근 runbook, Terraform 운영 문서, 변경 이력을 분리했다.
- 완료된 spec/plan 상세 문서는 이 파일의 요약 이력으로 압축했다.

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

## 2026-07-13: Argo Rollouts controller 설치 (#88)

- admin root `argo-rollouts-k8s`를 신설해 chart `argo-rollouts` 2.41.0을
  설치했다(dashboard 미설치 — kubectl plugin 운영). controller는 GCP API를
  쓰지 않아 NetworkPolicy egress가 DNS/K8s API로만 열린다(metadata·
  googleapis 규칙 없음 — vault-k8s보다 좁은 경계).
- RBAC은 chart upstream 기본 ClusterRole(전환 실행에 필요한 리소스 한정)을
  사용하고 근거를 root README에 기록했다.
- #87 spec의 "앱 배포 전 설치 금지" 문구는 기존 이슈 시리즈(#88~#90)와
  충돌해 "설치·샘플 검증 선행, 실 적용은 앱 배포 이슈"로 정정했다.

## 2026-07-13: Argo Rollouts 샘플 검증 (#89)

- 샘플 canary(2 replica, 50% → pause → 100%)로 배포→canary 정지→promote→
  abort→undo 전 흐름을 실측 검증하고 샘플을 폐기했다.
- 핵심 교훈: abort는 트래픽만 stable로 되돌리고 Degraded로 남는다 — 복구는
  spec을 되돌리는 것(ArgoCD 연결 후에는 Git revert가 원칙, CLI undo는
  OutOfSync 유발). pause 무기한 특성상 적용 앱은 N-1 호환이 전제다.
- metric 연동은 #87 결정대로 2단계 후속으로 유지한다(1단계 수동 promote).

## 2026-07-13: Argo Rollouts 운영 runbook (#90)

- #89 실측 명령 기준으로 `docs/ROLLOUTS_OPERATIONS_RUNBOOK.md`를 작성했다:
  상태 확인, 수동 promote(1단계 표준 — Grafana 확인 후), abort/rollback
  구분(Git revert 원칙), 실패 확인 순서, ArgoCD 연계 지점, 재현 manifest.

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

## 2026-07-13: ECK operator 설치 (#97)

- admin root `elastic-k8s`를 신설해 chart `eck-operator` 3.4.1을 설치했다.
  `managedNamespaces: [elastic]`으로 operator 감시 범위를 최소화했다.
- validating webhook은 포트를 10250으로 옮겨 private GKE 기본 master→node
  방화벽을 재사용했다(monitoring-k8s의 prometheusOperator.internalPort 선례
  — 별도 firewall 불필요).
- 이슈 본문의 elastic-system 대신 #96 설계대로 단일 namespace `elastic`을
  사용한다. CRD는 helm uninstall에도 남는다(삭제 시 CR 연쇄 삭제·데이터
  유실 — README 롤백 절 참조).

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

## 2026-07-13: Kibana 내부 접근 구성 (#99)

- Kibana CR(1 replica, ES와 동일 스택 버전, elasticsearchRef 연결)을
  elastic-k8s root에 추가했다. ClusterIP + port-forward 전용, LB/Ingress
  없음, TLS는 ECK 기본(self-signed).
- 노드 대역 → 5601 ingress는 #97 NetworkPolicy에 이미 선언되어 있다.
  elastic 사용자 비밀번호는 Secret 회수 절차만 사용(Git/문서 금지).

## 2026-07-13: 모니터링 스택 apply 완결 (#79 reopen)

- Grafana UI 접속 불가 확인 중 monitoring-k8s root가 apply된 적이 없음을
  발견했다(namespace 부재, state resources 0 — 7/9 시도 흔적만). 코드·
  runbook은 merge됐지만 스택은 미설치 상태였다.
- PVC(Prometheus 30Gi, Grafana 10Gi)에 `standard`(pd-standard)를 명시했다
  — 기본 standard-rwo였다면 SSD quota(#98과 동일)에 막혔을 것을 사전 차단.
- 교훈: apply·실검증까지가 이슈 완료 기준이라는 원칙을 재확인 — "코드
  merge = 완료"로 잘못 닫힌 이슈가 없는지 트랙 완료 시점에 state를 함께
  점검한다.

## 2026-07-13: Terraform drift 감지 자동화 (#153)

- 매일 1회 dev root plan -detailed-exitcode로 코드-인프라 불일치를 감지해
  [DRIFT] 이슈를 자동 생성하는 workflow를 추가했다(#79 미적용 스택 재발
  방지). CI SA의 기존 viewer 권한만 사용 — apply 권한 부여 없음.
- 자동 apply는 도입하지 않기로 결정했다: 권한 폭발(viewer→editor급),
  admin root의 구조적 CI 불가(master 접근), apply 시점 사람 검증의 가치
  (#116/#122/#98 인시던트 실증). 2단계(Environment approval 반자동)는
  별도 설계 후 검토한다.

## 2026-07-13: Grafana Google OAuth 로그인 (#155)

- 로그인을 admin 비밀번호 공유에서 Google OAuth(팀원 개인 계정)로 전환했다.
  client id/secret은 운영자 주입 Secret(grafana-google-oauth)의 env 참조로만
  구성 — values/Git/state에 값 없음.
- gmail은 도메인 제한이 불가능하므로 allow_sign_up=false + 계정 사전 생성
  방식으로 allowlist를 구현했다. 팀원 이메일은 Git/문서/이슈에 기록하지
  않고 Grafana DB에만 존재한다(이메일 비노출 요구).
- admin 계정은 비상용으로 유지. redirect URI는 port-forward 주소
  (localhost:3000) — 내부 전용 접근 원칙 유지.

## 2026-07-13: Filebeat 로그 수집 (#100)

- Beat CR(Filebeat DaemonSet)로 airflow·autoresearch namespace 컨테이너
  로그만 수집한다(autodiscover allowlist). 시스템/플랫폼 로그는 Cloud
  Logging 담당 — 중복 수집 방지 기준을 문서화했다.
- 전용 SA + 읽기 전용 ClusterRole(autodiscover 최소 권한), ES 연결은
  services CIDR 9200 egress 추가로 허용(pre-DNAT VIP — #122 교훈).
- hostPath read의 PSS baseline 위반은 audit/warn(비강제)로 수용하고
  근거를 README에 기록했다(#96에서 확인 예약된 항목의 결론).

## 2026-07-13: ES ILM/retention 정책 (#101)

- filebeat 기본 ILM(rollover 30d/50gb, 삭제 없음)을 hot rollover 1d/5gb +
  delete 7d로 교체했다(운영자 절차 — ES 내부 리소스는 Terraform 밖 원칙).
  PVC 30Gi 고정에서 무한 보관을 차단하는 비용 방지 장치다.
- filebeat 템플릿 replicas를 0으로 교체(Beat config setup.template) —
  기본값 1이 single-node에서 unassigned replica를 만들어 cluster가
  yellow였던 것을 green으로 복구했다(#96/#98 예고 지점 실측).
- dev/운영 보관 분리 기준: 운영 전환 시 delete min_age만 상향.

## 2026-07-13: ES GCS snapshot 백업 (#102)

- dev root에 snapshot 전용 bucket(es-snapshots)과 GSA/WI(키 없음)를
  추가했다. 권한은 bucket 단위 objectAdmin + legacyBucketReader만.
- ES pod를 전용 KSA(elasticsearch)로 전환하고 metadata egress를 열어
  repository-gcs가 ADC(WI)로 인증한다. SLM 일 1회(03:30 KST)·expire 7d.
- #96 spec의 "bucket lifecycle로 정리" 문구를 정정했다 — ES snapshot은
  증분(세그먼트 공유) 구조라 age 기반 객체 삭제가 최신 snapshot을
  손상시킨다. 정리는 SLM retention만 사용한다.

## 2026-07-13: Kibana/ELK 운영 runbook (#103) — ELK 트랙 완결

- #98~#102 검증에서 실행한 명령 기준으로 KIBANA_OPERATIONS_RUNBOOK을
  작성했다: 접속/data view, KQL 검색(Airflow 실패·앱 에러), K8s 이벤트는
  수집 범위 밖(kubectl/Grafana) 명시, 정기 점검(ILM delete phase·SLM
  last_success·PVC), 장애 1차 표(트랙 인시던트들 반영), 업그레이드 주의
  (operator 먼저 + kubernetes_manifest 수렴 재확인), 폐기 순서.
- 팀원용 Kibana 접속 절을 TEAM_OPERATIONS_RUNBOOK에 추가했다(상위 문서
  동시 점검 원칙).
- 이로써 ELK 트랙(#96~#103)이 완결됐다.

## 2026-07-13: GKE autoscaling 전략 검토 (#104)

- 실측: dev-default는 CA min1/max2로 이미 활성, airflow-dev는 min=max=1
  고정(의도), NAP/VPA 비활성.
- 결론: dev는 현행 유지. NAP 보류(워크로드 프로필 2종 고정 + 비용 예측성),
  **Karpenter 비권장 확정**(GKE 공식 지원 없음, CA/NAP가 네이티브 대체).
- 핵심 통찰: PVC(RWO) stateful pod들 때문에 scale-down이 점착적 — 확장은
  사실상 반영구 증설로 취급. 다음 개선은 autoscaling이 아니라 #105(Spot
  batch pool, ES 전용 pool 트리거)에 있다.

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

## 2026-07-13: 플랫폼 stateful dev-default 고정 (#170)

- #105 후속 ①. Prometheus/Grafana/Vault에 dev-default nodeSelector를
  적용해 "stateful 명시 고정" 원칙을 완성했다(ES/Kibana는 기적용).
- 계기: taint 부재로 Prometheus(30Gi PVC)가 작은 airflow 노드에 배치돼
  메모리 압박에 기여하던 실측 문제.

## 2026-07-14: GKE node pool 운영 최적화 1차 (#106)

- 실측(설치 직후 스냅샷) 기반 1차 조정: ① airflow pool max 1→2 — KPO
  배치 피크의 escape valve(평시 비용 불변, KPO는 일회성이라 scale-down
  회수됨) ② Prometheus(실측 508Mi)/Grafana(315Mi)에 requests/limits 부여
  — 미설정 상태는 스케줄러·CA 판단을 왜곡(#105 배치 문제의 원인 중 하나).
- machine type은 변경하지 않음(노드 재생성 회피 — rollback 기준: min/max와
  requests는 in-place 되돌림 가능).
- 한계 명시: 모니터링이 갓 설치되어 데이터 창이 짧다 — Prometheus 7일
  축적 후(7/21 전후) 피크 데이터로 2차 점검을 조건으로 남김.

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

## 2026-07-14: WIF pusher SA를 승인 ref로 제한 (#175)

- Codex adversarial review high finding. gar_pusher/application_pusher SA의
  principalSet이 repository만 검사해 임의 브랜치 workflow도 가장 가능했다
  (공급망 위험 — 악성 브랜치가 dev GAR 이미지 덮어쓰기).
- bootstrap WIF provider에 `repository_ref`(repo@ref) 조합 attribute를
  추가하고, 두 pusher principalSet을 승인 ref(기본 refs/heads/main)로
  좁혔다. terraform-ci(read-only)는 대상 외.
- 앱 저장소 실제 배포 ref는 협의 필요 — 기본값 main으로 시작, 태그 릴리스
  등은 확정 후 변수(airflow_deploy_ref/application_deploy_ref)로 조정.

## 2026-07-14: ES snapshot bucket soft delete 추가 (#176)

- Codex adversarial review high finding. snapshot GSA의 objectAdmin(SLM
  삭제에 필요)과 soft delete 0(복구 불가)이 결합돼, 침해/오작동/잘못된
  SLM이 객체를 삭제하면 원본과 유일 백업이 동시 소실될 수 있었다.
- soft delete를 7일(GCS 최소값)로 활성화해 삭제 객체 복구 창을 확보했다.
  SLM 정상 삭제는 그대로 성공하고 soft-deleted 사본만 뒤에 남으므로 증분
  구조와 충돌하지 않는다. retention lock은 SLM 정리를 막으므로 미사용.

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
