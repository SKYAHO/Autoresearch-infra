# #485 paired Feast experiment runtime은 기존 Airflow batch workload와 분리된
# identity를 사용한다. Job 생성은 후속 활성화까지 output으로 fail-closed 한다.
resource "google_service_account" "experiment_runtime" {
  account_id   = local.experiment_runtime_sa_name
  display_name = "Autoresearch dev paired experiment runtime workload identity SA"
  description  = "Limited to dev paired Feast experiment data and artifact prefixes."
}

# experiment-runtime namespace의 단일 KSA만 이 GSA를 가장할 수 있다.
resource "google_service_account_iam_member" "experiment_runtime_wi" {
  service_account_id = google_service_account.experiment_runtime.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.experiment_runtime_workload_identity_principal}"

  depends_on = [google_container_cluster.dev]
}

# GCS IAM condition은 request별 comparison ID/source SHA까지 표현할 수 없으므로
# experiments/와 code/ root까지만 Terraform에서 강제한다.
# #204/#205 실측 교훈: Feast GCS registry client는 bucket.reload()에
# storage.buckets.get을 요구하는데 objectViewer/objectAdmin 어디에도 없다.
# feast_apply_dev도 같은 이유로 legacyBucketReader를 함께 받는다
# (github_actions.tf의 feast_apply_dev_registry_bucket_reader). 이 보강이 없으면
# plan/validate는 통과하고 실제 Job 실행에서만 403이 난다.
#
# 주의(권한 확대): legacyBucketReader는 **버킷 수준** 역할이라 object prefix
# 조건을 걸 수 없다. 따라서 이 grant는 buckets.get과 함께 registry 버킷 전체의
# object LIST를 허용한다 — 아래 objectViewer의 experiments/ prefix 조건은
# 개별 객체 READ에만 적용된다(objects.list는 bucket resource에 대해 평가되므로
# prefix 조건으로는 애초에 LIST가 성립하지 않는다). dev registry 한정이고
# 객체 내용 읽기는 여전히 prefix로 묶이지만, "prefix 밖은 목록조차 안 보인다"는
# 보장은 하지 않는다는 점을 runbook에도 명시했다.
resource "google_storage_bucket_iam_member" "experiment_runtime_registry_bucket_reader" {
  bucket = google_storage_bucket.feast_registry_dev.name
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${google_service_account.experiment_runtime.email}"
}

resource "google_storage_bucket_iam_member" "experiment_runtime_registry_viewer" {
  bucket = google_storage_bucket.feast_registry_dev.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.experiment_runtime.email}"

  condition {
    title       = "experiment-runtime-registry-read"
    description = "Allow paired experiment runtime to read dev registry experiment objects only."
    expression  = "resource.name.startsWith('projects/_/buckets/${google_storage_bucket.feast_registry_dev.name}/objects/${local.experiment_runtime_experiments_prefix}')"
  }
}

resource "google_storage_bucket_iam_member" "experiment_runtime_staging_creator" {
  bucket = google_storage_bucket.feast_staging_dev.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.experiment_runtime.email}"

  condition {
    title       = "experiment-runtime-staging-create"
    description = "Allow paired experiment runtime to create dev staging experiment objects only."
    expression  = "resource.name.startsWith('projects/_/buckets/${google_storage_bucket.feast_staging_dev.name}/objects/${local.experiment_runtime_experiments_prefix}')"
  }
}

resource "google_storage_bucket_iam_member" "experiment_runtime_staging_viewer" {
  bucket = google_storage_bucket.feast_staging_dev.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.experiment_runtime.email}"

  condition {
    title       = "experiment-runtime-staging-read"
    description = "Allow paired experiment runtime to read dev staging experiment objects only."
    expression  = "resource.name.startsWith('projects/_/buckets/${google_storage_bucket.feast_staging_dev.name}/objects/${local.experiment_runtime_experiments_prefix}')"
  }
}

resource "google_storage_bucket_iam_member" "experiment_runtime_artifact_creator" {
  bucket = google_storage_bucket.mlflow_artifacts.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.experiment_runtime.email}"

  condition {
    title       = "experiment-runtime-artifact-create"
    description = "Allow paired experiment runtime to create MLflow experiment artifacts only."
    expression  = "resource.name.startsWith('projects/_/buckets/${google_storage_bucket.mlflow_artifacts.name}/objects/${local.experiment_runtime_experiments_prefix}')"
  }
}

resource "google_storage_bucket_iam_member" "experiment_runtime_artifact_viewer" {
  bucket = google_storage_bucket.mlflow_artifacts.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.experiment_runtime.email}"

  condition {
    title       = "experiment-runtime-artifact-read"
    description = "Allow paired experiment runtime to read MLflow experiment artifacts only."
    expression  = "resource.name.startsWith('projects/_/buckets/${google_storage_bucket.mlflow_artifacts.name}/objects/${local.experiment_runtime_experiments_prefix}')"
  }
}

resource "google_storage_bucket_iam_member" "experiment_runtime_code_viewer" {
  bucket = google_storage_bucket.code_artifacts.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.experiment_runtime.email}"

  condition {
    title       = "experiment-runtime-code-read"
    description = "Allow paired experiment runtime to read code archives only."
    expression  = "resource.name.startsWith('projects/_/buckets/${google_storage_bucket.code_artifacts.name}/objects/${local.experiment_runtime_code_prefix}')"
  }
}

# PIT query에 필요한 dev dataset read와 BigQuery job/read session 생성만 부여한다.
# production Feast/source dataset 및 write 권한은 의도적으로 포함하지 않는다.
resource "google_bigquery_dataset_iam_member" "experiment_runtime_feast_offline_store_dev_viewer" {
  dataset_id = google_bigquery_dataset.feast_offline_store_dev.dataset_id
  role       = "roles/bigquery.dataViewer"
  member     = "serviceAccount:${google_service_account.experiment_runtime.email}"
}

resource "google_project_iam_member" "experiment_runtime_bigquery_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.experiment_runtime.email}"
}

resource "google_project_iam_member" "experiment_runtime_bigquery_read_session" {
  project = var.project_id
  role    = "roles/bigquery.readSessionUser"
  member  = "serviceAccount:${google_service_account.experiment_runtime.email}"
}
