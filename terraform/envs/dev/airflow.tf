# #32 Airflow 운영 인프라 경계
# K8s namespace/RBAC + GCP SA(WI) + Cloud SQL DB + GCS 버킷. Airflow Helm values 자체는 앱 저장소 범위.

# --- GCP 서비스 계정 + Workload Identity ---

resource "google_service_account" "airflow" {
  account_id   = local.airflow_sa_name
  display_name = "Autoresearch dev Airflow workload identity SA"
}

resource "google_service_account_iam_member" "airflow_wi" {
  service_account_id = google_service_account.airflow.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.airflow_workload_identity_principal}"

  depends_on = [google_container_cluster.dev]
}

# --- GCP IAM (project-level) ---

resource "google_project_iam_member" "airflow_cloudsql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.airflow.email}"
}

resource "google_project_iam_member" "airflow_bigquery_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.airflow.email}"
}

# --- Cloud SQL metadata DB ---

resource "google_sql_database" "airflow" {
  name     = "airflow"
  instance = google_sql_database_instance.dev.name
}

# --- GCS 버킷 (DAG 버전관리, 로그 영속화) ---

resource "google_storage_bucket" "airflow_dags" {
  name                        = local.airflow_dags_bucket_name
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  versioning {
    enabled = true
  }

  soft_delete_policy {
    retention_duration_seconds = 0
  }

  labels = {
    data_class = "dags"
    purpose    = "airflow-dags"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_storage_bucket" "airflow_logs" {
  name                        = local.airflow_logs_bucket_name
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  labels = {
    data_class = "logs"
    purpose    = "airflow-logs"
  }

  lifecycle {
    prevent_destroy = true
  }
}

# --- GCS bucket IAM (airflow SA objectAdmin) ---

resource "google_storage_bucket_iam_member" "airflow_dags_admin" {
  bucket = google_storage_bucket.airflow_dags.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.airflow.email}"
}

resource "google_storage_bucket_iam_member" "airflow_logs_admin" {
  bucket = google_storage_bucket.airflow_logs.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.airflow.email}"
}

resource "google_storage_bucket_iam_member" "airflow_raw_data_admin" {
  bucket = google_storage_bucket.raw_data.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.airflow.email}"
}

resource "google_storage_bucket_iam_member" "airflow_feast_registry_admin" {
  bucket = google_storage_bucket.feast_registry.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.airflow.email}"
}

resource "google_storage_bucket_iam_member" "airflow_feast_staging_admin" {
  bucket = google_storage_bucket.feast_staging.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.airflow.email}"
}

# --- BigQuery dataset IAM ---

resource "google_bigquery_dataset_iam_member" "airflow_feast_data_editor" {
  dataset_id = google_bigquery_dataset.feast_offline_store.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.airflow.email}"
}
