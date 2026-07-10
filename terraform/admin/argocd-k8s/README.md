# ArgoCD Kubernetes Admin Root

이 root는 dev GKE의 ArgoCD 설치 기반을 별도 state로 관리한다. #83 범위에서는
`argocd` namespace와 Helm values 파일 위치만 준비하고, 실제 ArgoCD server,
controller, repo-server 설치는 후속 이슈에서 진행한다.

## 책임 범위

| 항목 | 이 root에서 관리 | 비고 |
|---|---|---|
| `argocd` namespace | 예 | `prevent_destroy`로 실수 삭제 방지 |
| ArgoCD Helm values 위치 | 예 | `helm-values/argo-cd.values.yaml` |
| ArgoCD Helm release | 아니오 | 후속 이슈 #84 |
| AppProject/Application | 아니오 | 후속 이슈 #85 |
| Secret payload | 아니오 | Secret Manager 또는 운영자 주입 |

## 사용 방법

```bash
cd terraform/admin/argocd-k8s
cp terraform.tfvars.example terraform.tfvars
# terraform.tfvars에 실제 project_id를 입력합니다. 이 파일은 커밋하지 않습니다.

terraform init
terraform plan
terraform apply
```

로컬 검증은 원격 state에 붙지 않고 실행할 수 있다.

```bash
terraform -chdir=terraform/admin/argocd-k8s fmt -check -recursive
terraform -chdir=terraform/admin/argocd-k8s init -backend=false
terraform -chdir=terraform/admin/argocd-k8s validate
```

## 설치 방식 결정

초기 ArgoCD 설치는 Helm chart 방식을 기준으로 한다. 이유는 다음과 같다.

- chart values를 Git에서 리뷰할 수 있다.
- 내부 접근, resource request, repo credential 참조 같은 운영 설정을 values로
  분리할 수 있다.
- 후속 이슈에서 chart version을 pin하고 `helm_release`로 lifecycle을 추적하기 쉽다.

`helm-values/argo-cd.values.yaml`은 설치 전 기본 scaffold다. 실제 chart version과
세부 values는 #84에서 검증 후 고정한다.

## Secret 처리 원칙

- repo credential, admin password, webhook secret, OAuth secret payload를 Git에
  커밋하지 않는다.
- Terraform 변수와 state에도 secret payload를 저장하지 않는다.
- private repository credential이 필요하면 Kubernetes Secret payload로 주입하고,
  Terraform/Helm values에는 Secret 이름과 key만 참조한다.
- Secret Manager, External Secrets Operator, Secret Manager CSI Driver 도입은
  별도 설계 후 진행한다.
