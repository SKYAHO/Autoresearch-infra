# Airflow 운영 인프라 경계 설계 (#32)

> Status: Review Updated | Issue: #32 | Last Updated: 2026-07-08

## 목적

dev GKE 클러스터에 Airflow를 설치할 수 있도록 인프라 경계를 만든다. 이 저장소가
담당하는 범위는 GCP 리소스와 Kubernetes namespace 경계까지이며, Airflow Helm
values, executor, OAuth, DAG 내용은 앱 저장소(`SKYAHO/Autoresearch`)에서 관리한다.

완료 후 설치 담당자는 `airflow` namespace에 Helm chart를 설치할 수 있고, Airflow
pod는 Workload Identity로 Cloud SQL, GCS, BigQuery에 접근한다. JSON key는 발급하지
않는다.

## 전제

- GKE 클러스터는 private nodes + public control plane endpoint이며
  `master_authorized_networks`로 접근을 제한한다.
- GitHub Actions PR plan runner는 GKE API 서버 허용 CIDR 안에 있지 않다.
- 따라서 PR plan이 실행되는 `terraform/envs/dev` root에는 Kubernetes provider를 두지
  않는다.
- Kubernetes 리소스는 별도 admin root에서 허용된 관리자 네트워크로 apply한다.

## 설계 결정

| 결정 | 내용 | 이유 |
|---|---|---|
| Terraform root 분리 | `terraform/envs/dev`는 GCP 리소스, `terraform/admin/airflow-k8s`는 K8s 리소스 관리 | CI plan이 GKE API 서버 접근 실패로 깨지는 것을 방지하고, apply 주체를 명확히 분리 |
| namespace 이름 | `airflow` | dev 단일 Airflow 설치 경계 |
| 설치 담당자 권한 | `installer_user_emails`에 등록된 사용자에게 `airflow` namespace 안에서만 `admin` ClusterRole 바인딩 | Helm 설치에 필요한 namespace-scoped 권한만 부여 |
| Airflow pod 인증 | K8s SA `airflow` + GCP SA `autoresearch-dev-airflow` Workload Identity 매핑 | 앱 SA와 Airflow SA를 분리하고 JSON key를 사용하지 않음 |
| WI annotation | `iam.gke.io/gcp-service-account` | GKE Workload Identity의 올바른 service account annotation key |
| Cloud SQL metadata DB | 기존 dev Cloud SQL 인스턴스 안에 `airflow` database 생성 | 별도 DB 서버 비용 없이 managed DB 사용 |
| Secret Manager | Airflow API key secret metadata와 Airflow SA/batch SA accessor 관리. payload는 Terraform 밖에서 주입 | 실제 secret 값을 state/plan에 남기지 않음. 기존 app SA 접근은 Airflow 전용 SA들로 축소 |
| GCS DAG/log | `airflow-dags`, `airflow-logs` 버킷 신규 생성, Airflow SA에 bucket-scoped `objectAdmin` | DAG 버전관리와 task log 영속화 |
| GCS raw_data | Airflow SA에 `objectViewer` + `objectCreator`만 부여 | 원본 데이터 읽기와 append는 허용하되 기존 원본 삭제/덮어쓰기는 차단 |
| GCS Feast registry/staging | Airflow SA에 bucket-scoped `objectAdmin` | registry 갱신과 staging 임시 파일 생성/삭제가 필요 |
| BigQuery | `feast_offline_store` dataset `dataEditor`, project-level `jobUser` | offline store 읽기/쓰기와 query job 실행 |
| NetworkPolicy ingress | 같은 namespace와 `kube-system`만 허용 | 기본 deny-by-default 경계 |
| NetworkPolicy egress | DNS 53, Cloud SQL private CIDR 5432, GKE metadata server `169.254.169.254:80`, HTTPS 443 | DNS, DB, Workload Identity 토큰 교환, Google APIs 접근에 필요한 최소 경로 |

## 리소스 구성

### GCP root: `terraform/envs/dev`

```
google_service_account.airflow
google_service_account.airflow_batch
google_service_account_iam_member.airflow_wi
google_service_account_iam_member.airflow_batch_wi
google_project_iam_member.airflow_cloudsql_client
google_project_iam_member.airflow_bigquery_job_user
google_project_iam_member.airflow_batch_bigquery_job_user
google_sql_database.airflow
google_secret_manager_secret.airflow_youtube_api_key
google_secret_manager_secret.airflow_openrouter_api_key
google_secret_manager_secret_iam_member.airflow_youtube_api_key_accessor
google_secret_manager_secret_iam_member.airflow_openrouter_api_key_accessor
google_secret_manager_secret_iam_member.airflow_batch_youtube_api_key_accessor
google_secret_manager_secret_iam_member.airflow_batch_openrouter_api_key_accessor
google_storage_bucket.airflow_dags
google_storage_bucket.airflow_logs
google_storage_bucket_iam_member.airflow_dags_admin
google_storage_bucket_iam_member.airflow_logs_admin
google_storage_bucket_iam_member.airflow_raw_data_viewer
google_storage_bucket_iam_member.airflow_raw_data_creator
google_storage_bucket_iam_member.airflow_batch_raw_data_viewer
google_storage_bucket_iam_member.airflow_batch_raw_data_creator
google_storage_bucket_iam_member.airflow_feast_registry_admin
google_storage_bucket_iam_member.airflow_feast_staging_admin
google_storage_bucket_iam_member.airflow_batch_feast_registry_admin
google_storage_bucket_iam_member.airflow_batch_feast_staging_admin
google_bigquery_dataset_iam_member.airflow_feast_data_editor
google_bigquery_dataset_iam_member.airflow_batch_feast_data_editor
```

### K8s admin root: `terraform/admin/airflow-k8s`

```
kubernetes_namespace_v1.airflow
kubernetes_service_account_v1.airflow
kubernetes_role_v1.airflow_components
kubernetes_role_binding_v1.airflow_sa
kubernetes_role_binding_v1.installer_admin
kubernetes_resource_quota_v1.airflow
kubernetes_limit_range_v1.airflow
kubernetes_network_policy_v1.airflow_ingress
kubernetes_network_policy_v1.airflow_egress
```

## Workload Identity 매핑

K8s SA annotation:

```hcl
"iam.gke.io/gcp-service-account" = local.airflow_gcp_service_account_email
```

GCP SA IAM member:

```hcl
member = "serviceAccount:<project>.svc.id.goog[airflow/airflow]"
role   = "roles/iam.workloadIdentityUser"
```

Airflow batch KSA(`airflow/autoresearch-batch`)는 app GSA가 아니라
batch 전용 GSA(`autoresearch-dev-airflow-batch`)를 가장한다. 실제 apply 전에
KSA annotation을 batch GSA 이메일로 맞춰야 하며, app GSA의 Airflow API key
secret accessor는 유지하지 않는다.

## 운영 절차

1. `terraform/envs/dev`에서 GCP 리소스를 plan/apply한다.
2. 허용된 관리자 네트워크에서 `terraform/admin/airflow-k8s`를 plan/apply한다.
3. 설치 담당자는 `gcloud container clusters get-credentials`로 kubeconfig를 받고
   `airflow` namespace에 Helm chart를 설치한다.
4. Helm values에서는 Terraform이 만든 KSA(`airflow`)를 existing service account로
   사용한다.

## 비목표

- Airflow Helm values 상세 구성(OAuth, fernet key, executor 선택, DAG 배포 방식)
- Airflow 전용 Cloud SQL 인스턴스
- prod 환경 구성
- 모니터링/알림
- 백업 자동화

## 리스크 / 롤백

- **CI plan이 K8s API 접근 실패**: K8s provider를 dev root에서 제거하고 admin root로
  분리해 회피한다.
- **NetworkPolicy로 WI 토큰 교환 차단**: egress에 GKE metadata server
  `169.254.169.254/32` TCP 80을 명시한다.
- **raw_data 원본 훼손**: Airflow SA는 raw_data bucket에서 삭제/덮어쓰기가 가능한
  `objectAdmin`을 받지 않고, `objectViewer` + `objectCreator`만 받는다.
- **secret payload 노출**: Terraform은 secret metadata와 IAM만 관리하고 version
  payload는 관리하지 않는다.
- **팀원 권한 회수**: admin root의 local `terraform.tfvars`에서 이메일을 제거하고
  apply하면 namespace RoleBinding이 삭제된다.
- **롤백**: GCP root와 K8s admin root에서 각각 리소스를 제거 후 apply한다. DAG/log
  버킷은 `prevent_destroy`로 보호되므로 삭제 시 별도 절차가 필요하다.

## 검증

- `terraform -chdir=terraform/envs/dev fmt -check -recursive`
- `terraform -chdir=terraform/envs/dev validate`
- `terraform -chdir=terraform/admin/airflow-k8s fmt -check -recursive`
- `terraform -chdir=terraform/admin/airflow-k8s validate`
- `git diff --check`
- apply 후 `kubectl -n airflow get namespace,sa,role,rolebinding,networkpolicy`
