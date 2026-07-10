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
