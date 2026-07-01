# Dev Terraform Environment

`terraform/envs/dev`는 AutoResearch dev GCP 인프라의 Terraform root module입니다.

#1 작업에서는 provider, 변수, 출력, backend 예시, 필수 API 목록만 준비합니다. 실제 GCP 리소스는 후속 이슈에서 추가합니다.

## 포함 범위

- Google provider 설정
- dev 환경 공통 변수
- 리소스 naming/label 공통값
- GCS backend 예시
- 후속 작업에서 필요한 GCP API 목록 output

## 제외 범위

- 실제 VPC, subnet 생성
- Artifact Registry repository 생성
- Cloud SQL instance 생성
- GKE cluster 생성
- GitHub OIDC service account/IAM 생성
- Terraform remote state bucket 생성

## 로컬 실행

```bash
terraform -chdir=terraform/envs/dev fmt -recursive
terraform -chdir=terraform/envs/dev init -backend=false
terraform -chdir=terraform/envs/dev validate
```

plan을 실행할 때는 로컬 전용 변수 파일을 만듭니다.

```bash
cp terraform/envs/dev/terraform.tfvars.example terraform/envs/dev/terraform.tfvars
terraform -chdir=terraform/envs/dev plan -var-file=terraform.tfvars
```

`terraform.tfvars`에는 실제 GCP project id가 들어갈 수 있으므로 커밋하지 않습니다.

## 기본 리전

dev 기본 리전은 `asia-northeast3`로 둡니다. 다른 리전을 사용할 경우 `region`, `zone` 변수를 변경합니다.

