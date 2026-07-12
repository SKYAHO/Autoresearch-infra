# 인프라 변경 이력 요약

완료된 설계 spec과 구현 plan의 핵심 결정만 보존한다. 현재 운영 절차는
`TEAM_OPERATIONS_RUNBOOK.md`와 `TERRAFORM_DEV.md`를 우선한다.

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
