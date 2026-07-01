# Terraform Dev Environment

이 문서는 `#1 Terraform dev 환경 기본 골격 구성` 결과를 팀원이 빠르게 이해하도록 정리합니다.

## 구조

```text
terraform/
├── README.md
├── envs/
│   └── dev/
│       ├── README.md
│       ├── backend.tf.example
│       ├── locals.tf
│       ├── main.tf
│       ├── outputs.tf
│       ├── providers.tf
│       ├── terraform.tfvars.example
│       ├── variables.tf
│       └── versions.tf
└── modules/
    └── README.md
```

## 현재 단계에서 생성하지 않는 것

#1은 Terraform 실행 골격만 구성합니다. 아래 리소스는 생성하지 않습니다.

- VPC/subnet
- Artifact Registry repository
- Cloud SQL instance
- GKE cluster
- GitHub OIDC IAM/service account
- Terraform remote state bucket

## 필수 GCP API 후보

아래 API는 후속 이슈에서 필요한 후보입니다. #1에서는 Terraform output으로 목록만 정리하며, 실제 enable은 별도 이슈나 승인 후 진행합니다.

| API | 사용 예정 |
|---|---|
| `serviceusage.googleapis.com` | GCP API enable 관리 |
| `cloudresourcemanager.googleapis.com` | project metadata 조회 및 관리 |
| `compute.googleapis.com` | VPC/subnet, GKE 기반 네트워크 |
| `artifactregistry.googleapis.com` | Docker image repository |
| `sqladmin.googleapis.com` | Cloud SQL |
| `container.googleapis.com` | GKE |
| `iam.googleapis.com` | service account, IAM binding |
| `iamcredentials.googleapis.com` | GitHub OIDC 기반 credential 생성 |
| `sts.googleapis.com` | Workload Identity Federation token exchange |
| `secretmanager.googleapis.com` | secret 저장 및 참조 |
| `logging.googleapis.com` | 운영 로그 |
| `monitoring.googleapis.com` | 모니터링 |

## 검증 명령

```bash
terraform -chdir=terraform/envs/dev fmt -recursive
terraform -chdir=terraform/envs/dev init -backend=false
terraform -chdir=terraform/envs/dev validate
git diff --check
```

`terraform init`은 provider plugin을 내려받기 때문에 네트워크가 필요합니다.

