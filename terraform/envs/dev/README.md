# Dev Terraform Environment

`terraform/envs/dev`는 AutoResearch dev GCP 인프라의 Terraform root module입니다.

현재 dev 스택은 GCS 원격 backend를 사용하며, 2026-07-06 기준 GCP 프로젝트 `ar-infra-501607`에 apply 완료되었습니다.

## 포함 범위

- Google provider 설정
- dev 환경 공통 변수
- 리소스 naming/label 공통값
- GCS backend(`autoresearch-dev-tfstate`, prefix `dev/`)
- dev VPC/subnet, Cloud Router/NAT, IAP SSH firewall
- Artifact Registry Docker repository
- Cloud SQL PostgreSQL(private IP only), DB/user, DB password Secret Manager 저장
- dev 원본 데이터 GCS bucket(YouTube/user/action-log/persona raw)
- dev BigQuery analytics dataset
- GKE Standard private-node cluster, node pool, node/app service account, Workload Identity binding
- GitHub Actions plan용 bootstrap 리소스는 `terraform/bootstrap`에서 별도 관리

## 로컬 실행

```bash
terraform -chdir=terraform/envs/dev fmt -recursive
terraform -chdir=terraform/envs/dev init
terraform -chdir=terraform/envs/dev validate
```

plan/apply를 실행할 때는 로컬 전용 변수 파일을 만듭니다.

```bash
cp terraform/envs/dev/terraform.tfvars.example terraform/envs/dev/terraform.tfvars
terraform -chdir=terraform/envs/dev plan
terraform -chdir=terraform/envs/dev apply
```

`terraform.tfvars`에는 실제 GCP project id가 들어갈 수 있으므로 커밋하지 않습니다.

## 현재 생성된 주요 리소스

| 영역 | 리소스 |
|---|---|
| Network | `autoresearch-dev-vpc`, `autoresearch-dev-subnet`, `autoresearch-dev-router`, `autoresearch-dev-nat` |
| Artifact Registry | `autoresearch-dev-docker` |
| Cloud SQL | `autoresearch-dev-pg`, DB `autoresearch`, user `app`, private IP `192.168.0.3` |
| GCS | `ar-infra-501607-autoresearch-dev-raw-data` |
| BigQuery | `autoresearch_dev_analytics` (#20 plan/apply 후) |
| Secret Manager | `projects/ar-infra-501607/secrets/autoresearch-dev-db-password` |
| GKE | `autoresearch-dev-gke`, node pool `dev-default` |
| IAM | GKE node SA, app SA, Cloud SQL/Secret/Workload Identity 권한 |

## 기본 리전

dev 기본 리전은 `asia-northeast3`로 둡니다. 다른 리전을 사용할 경우 `region`, `zone` 변수를 변경합니다.
