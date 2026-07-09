# Terraform

이 디렉터리는 `autoresearch-infra`의 Terraform 코드를 관리합니다.

현재 구성:

```text
terraform/
├── admin/          # 운영자 전용 별도 state root(gke-team-access, airflow-k8s)
├── bootstrap/      # GCS backend + GitHub WIF/CI SA 1회성 bootstrap
├── envs/
│   └── dev/        # dev 환경 root module(GCS backend)
└── modules/        # 재사용 module 예정
```

## 환경

| 환경 | 경로 | 용도 |
|---|---|---|
| dev | `terraform/envs/dev` | AutoResearch dev 인프라 검증 및 초기 운영 |
| admin | `terraform/admin/gke-team-access` | 팀원 Google 계정의 GKE `container.viewer` + bastion 접속 IAM |
| admin | `terraform/admin/airflow-k8s` | Airflow Kubernetes namespace/RBAC/NetworkPolicy |

## 기본 명령

```bash
terraform -chdir=terraform/envs/dev fmt -recursive
terraform -chdir=terraform/envs/dev init
terraform -chdir=terraform/envs/dev validate
```

실제 plan/apply를 실행할 때는 `terraform/envs/dev/terraform.tfvars.example`을 참고해 로컬 전용 `terraform.tfvars`를 만들고 사용합니다.

```bash
cp terraform/envs/dev/terraform.tfvars.example terraform/envs/dev/terraform.tfvars
terraform -chdir=terraform/envs/dev plan
terraform -chdir=terraform/envs/dev apply
```

`terraform.tfvars`, state, plan 파일은 커밋하지 않습니다.

## Backend

dev root module은 GCS backend를 사용합니다.

- bucket: `autoresearch-dev-tfstate`
- prefix: `dev/`

backend bucket과 GitHub Actions plan용 WIF/CI SA는 `terraform/bootstrap`에서 1회성으로 관리합니다. 자세한 내용은 [../docs/TERRAFORM_BOOTSTRAP.md](../docs/TERRAFORM_BOOTSTRAP.md)를 참고합니다.
