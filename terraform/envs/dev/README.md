# Dev Terraform Environment

`terraform/envs/dev`는 AutoResearch dev GCP 인프라의 Terraform root module입니다.

현재 dev 스택은 GCS 원격 backend를 사용하며, 2026-07-08 기준 GCP 프로젝트 `ar-infra-501607`에 apply 완료되었습니다.

## 포함 범위

- Google provider 설정
- dev 환경 공통 변수
- 리소스 naming/label 공통값
- GCS backend(`autoresearch-dev-tfstate`, prefix `dev/`)
- dev VPC/subnet, Cloud Router/NAT, IAP SSH firewall
- Artifact Registry Docker repository
- Cloud SQL PostgreSQL(private IP only), DB/user, DB password Secret Manager 저장
- dev 원본 데이터 GCS bucket(YouTube/user/action-log/persona raw)
- Feast registry/staging GCS bucket
- dev BigQuery analytics dataset 및 Feast offline store dataset
- GKE Standard private-node cluster, node pool, node/app service account, Workload Identity binding
- Airflow GCP 리소스: 전용 GCP SA/WI IAM, metadata DB, DAG/log bucket, BigQuery/GCS IAM
- Airflow 전용 GKE node pool(`airflow-dev`)과 batch KSA Workload Identity binding
- Airflow YouTube/OpenRouter API key용 Secret Manager secret metadata
- Airflow Kubernetes namespace/RBAC/NetworkPolicy는 `terraform/admin/airflow-k8s`에서 별도 state로 관리
- Autoresearch-airflow Cloud Build image push용 최소 IAM
- Cloud Run proxy state/code 정합성
- GKE 컨트롤 플레인 DNS 엔드포인트 — IAM 기반 kubectl 접속 (#45/#46)
- IAP 전용 bastion host(`bastion.tf`, 외부 IP 없음) (#47/#50)
- Airflow internal ILB 고정 IP(`10.10.0.12`)와 private DNS zone `dev.autoresearch.internal`(`dns.tf`) (#48/#51)
- Airflow Google OAuth client 자격증명용 Secret Manager secret metadata (#54/#55)
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
| GCS | `ar-infra-501607-autoresearch-dev-raw-data`, `ar-infra-501607-feast-registry`, `ar-infra-501607-feast-staging`, `ar-infra-501607-autoresearch-dev-airflow-dags`, `ar-infra-501607-autoresearch-dev-airflow-logs` |
| BigQuery | `autoresearch_dev_analytics`, `feast_offline_store` |
| Secret Manager | `autoresearch-dev-db-password`, `autoresearch-dev-youtube-api-key`, `autoresearch-dev-openrouter-api-key`, `autoresearch-dev-airflow-oauth-client-id`, `autoresearch-dev-airflow-oauth-client-secret` |
| GKE | `autoresearch-dev-gke`, node pools `dev-default`, `airflow-dev`, 컨트롤 플레인 DNS 엔드포인트(#45/#46) |
| Bastion | `autoresearch-dev-bastion` (IAP 전용, 외부 IP 없음, #47/#50) |
| DNS/ILB | private DNS zone `dev.autoresearch.internal`, Airflow ILB 고정 IP `10.10.0.12` (#48/#51) |
| IAM | GKE node SA, app SA, Airflow SA, Cloud SQL/Secret/BigQuery/GCS/Workload Identity 권한 |

## 기본 리전

dev 기본 리전은 `asia-northeast3`로 둡니다. 다른 리전을 사용할 경우 `region`, `zone` 변수를 변경합니다.
