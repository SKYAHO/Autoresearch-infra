# #32 Airflow 운영 인프라 경계
# GCP SA(WI) + Cloud SQL DB + GCS 버킷/IAM. Kubernetes namespace/RBAC는
# terraform/admin/airflow-k8s에서 별도 관리한다.

# --- GCP 서비스 계정 + Workload Identity ---

resource "google_service_account" "airflow" {
  account_id   = local.airflow_sa_name
  display_name = "Autoresearch dev Airflow workload identity SA"
}

resource "google_service_account" "airflow_batch" {
  account_id   = local.airflow_batch_sa_name
  display_name = "Autoresearch dev Airflow batch workload identity SA"
}

resource "google_service_account_iam_member" "airflow_wi" {
  service_account_id = google_service_account.airflow.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.airflow_workload_identity_principal}"

  depends_on = [google_container_cluster.dev]
}

# #240 lake_to_bigquery_incremental DAG는 KubernetesPodOperator가 아니라
# 스케줄러 파드 안에서 Google provider 오퍼레이터(GCS 센서, BigQuery job)를
# 직접 실행하므로, Helm chart가 생성하는 스케줄러 KSA(airflow-scheduler)도
# airflow GSA를 가장할 수 있어야 한다. KSA annotation은 Autoresearch-airflow
# 저장소의 Helm values(scheduler.serviceAccount.annotations)에서 관리한다.
resource "google_service_account_iam_member" "airflow_scheduler_wi" {
  service_account_id = google_service_account.airflow.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.airflow_scheduler_workload_identity_principal}"

  depends_on = [google_container_cluster.dev]
}

resource "google_service_account_iam_member" "airflow_batch_wi" {
  service_account_id = google_service_account.airflow_batch.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.airflow_batch_workload_identity_principal}"

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

resource "google_project_iam_member" "airflow_batch_bigquery_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.airflow_batch.email}"
}

# feast materialize는 BigQuery offline store를 Storage Read API로 읽는다.
# airflow/airflow_batch도 feast를 실행하므로 gke_app과 동일하게 readSessionUser 보강. (#204)
resource "google_project_iam_member" "airflow_bigquery_read_session" {
  project = var.project_id
  role    = "roles/bigquery.readSessionUser"
  member  = "serviceAccount:${google_service_account.airflow.email}"
}

resource "google_project_iam_member" "airflow_batch_bigquery_read_session" {
  project = var.project_id
  role    = "roles/bigquery.readSessionUser"
  member  = "serviceAccount:${google_service_account.airflow_batch.email}"
}

# --- Cloud SQL metadata DB ---

resource "google_sql_database" "airflow" {
  name     = "airflow"
  instance = google_sql_database_instance.dev.name
}

# --- Secret Manager (Airflow API key placeholders; payloads are managed out of Terraform) ---

resource "google_secret_manager_secret" "airflow_youtube_api_key" {
  secret_id = local.airflow_youtube_api_key_secret_id

  replication {
    auto {}
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_secret_manager_secret" "airflow_openrouter_api_key" {
  secret_id = local.airflow_openrouter_api_secret_id

  replication {
    auto {}
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_secret_manager_secret_iam_member" "airflow_youtube_api_key_accessor" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.airflow_youtube_api_key.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.airflow.email}"
}

resource "google_secret_manager_secret_iam_member" "airflow_openrouter_api_key_accessor" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.airflow_openrouter_api_key.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.airflow.email}"
}

resource "google_secret_manager_secret_iam_member" "airflow_batch_youtube_api_key_accessor" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.airflow_youtube_api_key.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.airflow_batch.email}"
}

resource "google_secret_manager_secret_iam_member" "airflow_batch_openrouter_api_key_accessor" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.airflow_openrouter_api_key.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.airflow_batch.email}"
}

# #54 Airflow 웹 로그인 Google OAuth 클라이언트 자격증명.
# 콘솔에서 수동 생성한 client ID/secret의 저장소만 Terraform으로 관리하고,
# payload(실값)는 관리자가 gcloud secrets versions add로 등록한다.
# 소비 주체는 Airflow webserver(airflow SA)뿐이므로 accessor는 airflow SA에만 부여.
resource "google_secret_manager_secret" "airflow_oauth_client_id" {
  secret_id = local.airflow_oauth_client_id_secret_id

  replication {
    auto {}
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_secret_manager_secret" "airflow_oauth_client_secret" {
  secret_id = local.airflow_oauth_client_secret_secret_id

  replication {
    auto {}
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_secret_manager_secret_iam_member" "airflow_oauth_client_id_accessor" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.airflow_oauth_client_id.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.airflow.email}"
}

resource "google_secret_manager_secret_iam_member" "airflow_oauth_client_secret_accessor" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.airflow_oauth_client_secret.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.airflow.email}"
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

# --- GCS bucket IAM ---

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

# Airflow는 raw landing 데이터를 읽고 새 raw 객체를 추가할 수 있지만,
# 기존 원본 데이터 삭제나 덮어쓰기는 할 수 없다.
resource "google_storage_bucket_iam_member" "airflow_raw_data_viewer" {
  bucket = google_storage_bucket.raw_data.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.airflow.email}"
}

resource "google_storage_bucket_iam_member" "airflow_raw_data_creator" {
  bucket = google_storage_bucket.raw_data.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.airflow.email}"
}

resource "google_storage_bucket_iam_member" "airflow_batch_raw_data_viewer" {
  bucket = google_storage_bucket.raw_data.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.airflow_batch.email}"
}

resource "google_storage_bucket_iam_member" "airflow_batch_raw_data_creator" {
  bucket = google_storage_bucket.raw_data.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.airflow_batch.email}"
}

# Feast registry/staging은 registry 갱신과 임시 staging 파일 처리에 객체 변경이 필요하다.
# 프로젝트 전체가 아니라 bucket 단위 권한으로 제한한다.
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

resource "google_storage_bucket_iam_member" "airflow_batch_feast_registry_admin" {
  bucket = google_storage_bucket.feast_registry.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.airflow_batch.email}"
}

resource "google_storage_bucket_iam_member" "airflow_batch_feast_staging_admin" {
  bucket = google_storage_bucket.feast_staging.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.airflow_batch.email}"
}

# feast GCS registry의 bucket.reload()에 필요한 storage.buckets.get 보강.
# objectAdmin에는 없어 legacyBucketReader로 딱 그 권한만 추가한다. (#204)
resource "google_storage_bucket_iam_member" "airflow_feast_registry_bucket_reader" {
  bucket = google_storage_bucket.feast_registry.name
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${google_service_account.airflow.email}"
}

resource "google_storage_bucket_iam_member" "airflow_feast_staging_bucket_reader" {
  bucket = google_storage_bucket.feast_staging.name
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${google_service_account.airflow.email}"
}

resource "google_storage_bucket_iam_member" "airflow_batch_feast_registry_bucket_reader" {
  bucket = google_storage_bucket.feast_registry.name
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${google_service_account.airflow_batch.email}"
}

resource "google_storage_bucket_iam_member" "airflow_batch_feast_staging_bucket_reader" {
  bucket = google_storage_bucket.feast_staging.name
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${google_service_account.airflow_batch.email}"
}

# --- BigQuery dataset IAM ---

resource "google_bigquery_dataset_iam_member" "airflow_feast_data_editor" {
  dataset_id = google_bigquery_dataset.feast_offline_store.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.airflow.email}"
}

resource "google_bigquery_dataset_iam_member" "airflow_batch_feast_data_editor" {
  dataset_id = google_bigquery_dataset.feast_offline_store.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.airflow_batch.email}"
}

# #285 raw 테이블이 data_lake_raw dataset으로 이전되면서, lake_to_bigquery
# DAG(Airflow SA)와 배치 job(Airflow batch SA)이 기존 권한을 잃지 않도록
# feast_offline_store와 동일한 dataEditor를 새 dataset에도 부여한다.
resource "google_bigquery_dataset_iam_member" "airflow_data_lake_raw_data_editor" {
  dataset_id = google_bigquery_dataset.data_lake_raw.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.airflow.email}"
}

resource "google_bigquery_dataset_iam_member" "airflow_batch_data_lake_raw_data_editor" {
  dataset_id = google_bigquery_dataset.data_lake_raw.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.airflow_batch.email}"
}
