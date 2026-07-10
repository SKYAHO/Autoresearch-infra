# ArgoCD Kubernetes Admin Root

이 root는 dev GKE의 ArgoCD 설치를 별도 state로 관리한다. #83에서 `argocd`
namespace와 values 위치를 준비했고, #84에서 argo-cd Helm release를 추가했다.
AppProject/Application 리소스는 후속 이슈 #85에서 추가한다.

## 책임 범위

| 항목 | 이 root에서 관리 | 비고 |
|---|---|---|
| `argocd` namespace | 예 | `prevent_destroy`로 실수 삭제 방지 |
| ArgoCD Helm release | 예 | chart `argo-cd` `10.1.3` pin (#84) |
| ArgoCD Helm values | 예 | `helm-values/argo-cd.values.yaml` |
| AppProject/Application | 아니오 | 후속 이슈 #85 |
| Secret payload | 아니오 | Secret Manager 또는 운영자 주입 |

## 설치 구성 (#84)

| 항목 | 값 | 비고 |
|---|---|---|
| Chart | `argo-cd` `10.1.3` (ArgoCD v3.4.5) | `var.argo_cd_chart_version` |
| Release | `argo-cd` | `var.argo_cd_release_name` |
| server Service | `ClusterIP` | 외부 공개 금지. LoadBalancer/Ingress 없음 |
| NetworkPolicy | deny-by-default ingress/egress (#116) | 아래 네트워크 경계 참조 |
| dex (SSO) | disabled | SSO 도입 시 별도 이슈에서 활성화 |
| notifications | disabled | 알림 채널 결정 후 활성화 |
| applicationSet | replicas 0 (중지) | chart 8.0부터 enabled 키가 제거됨(#115). ApplicationSet CR 사용 시 1로 복원 |

## 네트워크 경계 (#116)

`ClusterIP`는 인터넷 노출만 막고 클러스터 내부 접근은 막지 않으므로, 다른
namespace 워크로드가 ArgoCD 제어면에 접근하지 못하도록 deny-by-default
NetworkPolicy를 둔다. enforcement는 dev root(`gke.tf`)의 Calico 활성화가 전제다.

| 방향 | 허용 | 이유 |
|---|---|---|
| ingress | 같은 namespace | 컴포넌트 간 통신 (server ↔ repo-server ↔ redis ↔ controller) |
| ingress | kube-system | 시스템 컴포넌트 |
| ingress | `var.ui_ingress_source_cidr`(dev subnet) → 8080 | `kubectl port-forward` 트래픽은 노드 IP에서 출발하므로 노드 대역 허용이 없으면 UI 접근이 차단된다 |
| egress | 같은 namespace | redis(6379), repo-server(8081) 등 |
| egress | kube-system 53 (UDP/TCP) | DNS |
| egress | 0.0.0.0/0 443 | Git/Helm repository, Kubernetes API. git ssh(22)는 미사용이라 미허용 |

## 사용 방법

```bash
cd terraform/admin/argocd-k8s
cp terraform.tfvars.example terraform.tfvars
# terraform.tfvars에 실제 project_id를 입력합니다. 이 파일은 커밋하지 않습니다.

terraform init
terraform plan
terraform apply
```

실행 환경에는 dev GKE API 접근 경로와 `argocd` namespace 및 CRD,
ClusterRole/ClusterRoleBinding을 만들 수 있는 Kubernetes 권한이 필요하다.
argo-cd chart는 CRD와 cluster-wide RBAC를 포함하므로 namespace admin만으로는
부족하다. 일반 PR CI가 아니라 운영자 환경에서만 plan/apply한다.

로컬 검증은 원격 state에 붙지 않고 실행할 수 있다.

```bash
terraform -chdir=terraform/admin/argocd-k8s fmt -check -recursive
terraform -chdir=terraform/admin/argocd-k8s init -backend=false
terraform -chdir=terraform/admin/argocd-k8s validate
```

## 설치 후 확인

```bash
kubectl -n argocd get pods
# 외부 공개 리소스가 없는지 검증: 모든 Service가 ClusterIP여야 한다.
kubectl -n argocd get svc
kubectl -n argocd get ingress
```

## UI 접근 (내부 전용)

ArgoCD UI는 인터넷에 공개하지 않는다. 접근은 kubectl port-forward만 사용한다.

```bash
kubectl -n argocd port-forward svc/argo-cd-argocd-server 8443:443
```

브라우저에서 `https://localhost:8443`으로 접속한다. self-signed 인증서 경고는
dev 내부 접근 경로 특성상 허용한다.

## 초기 admin credential 처리

chart가 최초 설치 시 `argocd-initial-admin-secret`에 임시 admin 비밀번호를
생성한다. 처리 절차:

```bash
# 1) 초기 비밀번호 회수 (값을 문서/PR/채팅에 남기지 않는다)
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d

# 2) UI 또는 argocd CLI로 로그인 후 즉시 비밀번호 변경
# 3) 초기 secret 삭제
kubectl -n argocd delete secret argocd-initial-admin-secret
```

변경한 admin 비밀번호는 팀 비밀번호 관리 경로로만 공유한다. Git, PR,
Terraform state, values 파일에 저장하지 않는다.

## Secret 처리 원칙

- repo credential, admin password, webhook secret, OAuth secret payload를 Git에
  커밋하지 않는다.
- Terraform 변수와 state에도 secret payload를 저장하지 않는다.
- private repository credential이 필요하면 Kubernetes Secret payload로 주입하고,
  Terraform/Helm values에는 Secret 이름과 key만 참조한다.
- Secret Manager, External Secrets Operator, Secret Manager CSI Driver 도입은
  별도 설계 후 진행한다.

## 롤백

- `helm_release.argo_cd` 리소스를 제거하고 apply하면 release가 삭제된다.
  namespace는 `prevent_destroy`로 남는다.
- chart 버전 롤백은 `argo_cd_chart_version`을 이전 버전으로 되돌려 apply한다.
- ArgoCD는 이 시점(#84)에는 Application을 관리하지 않으므로 release 삭제가
  다른 워크로드에 영향을 주지 않는다.
