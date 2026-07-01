# Terraform Modules

재사용 가능한 Terraform module을 두는 디렉터리입니다.

초기 계획:

| 예정 module | 담당 이슈 | 목적 |
|---|---|---|
| `network` | `#2` | dev VPC, subnet, 네트워크 기본값 |
| `artifact-registry` | `#3` | Docker image repository |
| `cloud-sql` | `#4` | 최소 비용 dev database |
| `gke` | `#5` | 작은 dev Kubernetes cluster |
| `github-oidc` | `#6` | GitHub Actions OIDC 인증 기반 |

#1에서는 module 디렉터리만 준비하고 실제 resource는 추가하지 않습니다.

