# Terraform

이 디렉터리는 `autoresearch-infra`의 Terraform 코드를 관리합니다.

현재 구성:

```text
terraform/
├── envs/
│   └── dev/        # dev 환경 root module
└── modules/        # 재사용 module 예정
```

## 환경

| 환경 | 경로 | 용도 |
|---|---|---|
| dev | `terraform/envs/dev` | AutoResearch dev 인프라 검증 및 초기 운영 |

## 기본 명령

```bash
terraform -chdir=terraform/envs/dev fmt -recursive
terraform -chdir=terraform/envs/dev init -backend=false
terraform -chdir=terraform/envs/dev validate
```

실제 plan/apply를 실행할 때는 `terraform/envs/dev/terraform.tfvars.example`을 참고해 로컬 전용 `terraform.tfvars`를 만들고 사용합니다.

```bash
cp terraform/envs/dev/terraform.tfvars.example terraform/envs/dev/terraform.tfvars
terraform -chdir=terraform/envs/dev plan -var-file=terraform.tfvars
```

`terraform.tfvars`, state, plan 파일은 커밋하지 않습니다.

## Backend

#1 단계에서는 원격 backend bucket을 만들지 않습니다. 따라서 기본 local backend로 검증합니다.

GCS backend를 사용할 준비가 되면 `terraform/envs/dev/backend.tf.example`을 기준으로 `backend.tf`를 만들고, state bucket 생성 및 접근 권한을 별도 작업에서 확정합니다.

