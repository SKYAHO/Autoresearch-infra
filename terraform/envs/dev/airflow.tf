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

# #514 프로젝트 이전 중 storage.objects.delete 권한이 누락돼 원자적 게시
# (임시 이름으로 쓰고 최종 이름으로 옮기는 copy+delete, GCS에는 rename이 없음)가
# 실패하며 action log 파티션이 오염됐다. objectUser(create/get/list/delete/update
# 포함, IAM 정책 변경 권한은 없음)를 부여한다.
#
# 당초 `.staging-<uuid>` 접미사만 delete 대상으로 허용하는 조건(`resource.name.matches(...)`)을
# 시도했으나, `gcloud alpha iam policies lint-condition`으로 실제 GCS 버킷 리소스에 대해
# 검증한 결과 `matches()`/`contains()` 모두 `undeclared reference` 컴파일 오류로 거부된다
# (GCS 객체 조건은 `startsWith()`/`endsWith()`/`==`만 지원, RE2 정규식·부분 문자열 매치 불가).
# `terraform validate`/`plan`은 CEL을 파싱하지 않아 이 실패를 잡지 못하고 setIamPolicy
# 시점에야 드러난다. 임시 객체명은 끝에 랜덤 UUID가 붙어(`part-0.parquet.staging-<uuid>`)
# `endsWith()`로도 고정할 수 없으므로, 이름 패턴으로 staging 객체만 골라내는 조건은
# 현재 지원 함수로 표현이 불가능하다.
#
# 따라서 스코프를 이름 패턴이 아니라 **경로 prefix**로 좁혔었다(`local.raw_data_prefixes.action_logs_raw`,
# 당시 이슈가 지목한 실제 오염 경로).
#
# #522 후속: 앱 저장소(`Autoresearch`) 자신의 PR #517(이 저장소 PR #517과는 별개 —
# 저장소마다 번호가 독립적이다)이 이 조건이 머지되기 1시간 전에 이미 staging 객체
# 위치를 파티션 안(`<dest>.staging-<uuid>`)에서 버킷 루트의 고정 prefix
# (`_publish_staging/<uuid>.tmp`)로 옮겼다. `action_logs_raw`에 스코프한 조건은
# 앱이 실제로 만드는 staging 객체를 커버하지 못해 delete가 계속 403으로 실패했고,
# 라이브 확인(2026-08-05)에서 고아 staging 객체 1개가 실제로 발견됐다. 이제는
# `publish_staging_raw`로 스코프를 옮긴다 — 부수 효과로 이미 커밋된 action log
# 최종 객체(`data_lake/action_log/`)에는 더 이상 delete/update 권한이 없어,
# "완료된 raw 데이터는 삭제·덮어쓰기 불가" 원칙이 IAM 수준에서도 다시 성립한다.
# 다른 raw_data prefix(`asset/virtual_user/`, `data/raw/personas/` 등)는 이
# 바인딩의 영향을 받지 않는다.
resource "google_storage_bucket_iam_member" "airflow_batch_raw_data_staging_cleanup" {
  bucket = google_storage_bucket.raw_data.name
  role   = "roles/storage.objectUser"
  member = "serviceAccount:${google_service_account.airflow_batch.email}"

  condition {
    title       = "raw-data-publish-staging-delete-update"
    description = "Allow Airflow batch workloads to delete/update objects under the shared atomic-publish staging prefix (needed to clean up their own temp files; GCS IAM conditions cannot pattern-match the staging filename suffix)."
    expression  = "resource.type == 'storage.googleapis.com/Object' && resource.name.startsWith('projects/_/buckets/${google_storage_bucket.raw_data.name}/objects/${local.raw_data_prefixes.publish_staging_raw}')"
  }
}

# #464 canonical training snapshot publisher/consumer 경계. 기존 MLflow 서버의
# bucket-wide artifact 권한을 학습 파드에 상속하지 않고, batch GSA에만 prefix
# 한정 create/read를 부여한다. objectCreator는 기존 객체 overwrite를 막는다.
resource "google_storage_bucket_iam_member" "airflow_batch_mlflow_training_snapshot_creator" {
  bucket = google_storage_bucket.mlflow_artifacts.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.airflow_batch.email}"

  condition {
    title       = "training-snapshot-prefix-create"
    description = "Allow Airflow batch workloads to create immutable training snapshots only."
    expression  = "resource.name.startsWith('projects/_/buckets/${google_storage_bucket.mlflow_artifacts.name}/objects/${local.mlflow_training_snapshot_prefix}')"
  }
}

resource "google_storage_bucket_iam_member" "airflow_batch_mlflow_training_snapshot_viewer" {
  bucket = google_storage_bucket.mlflow_artifacts.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.airflow_batch.email}"

  condition {
    title       = "training-snapshot-prefix-read"
    description = "Allow Airflow batch workloads to verify and compare training snapshots only."
    expression  = "resource.name.startsWith('projects/_/buckets/${google_storage_bucket.mlflow_artifacts.name}/objects/${local.mlflow_training_snapshot_prefix}')"
  }
}

# #577 실험 executor Job이 학습 입력으로 같은 canonical 스냅샷을 읽는다.
#
# #464가 이 스토어를 만든 동기에 "seed sweep이나 baseline/challenger 학습을 반복하면
# 동일 CSV가 각 MLflow run artifact에 중복 저장된다"가 들어 있다. 실험 파이프라인이
# 바로 그 baseline/challenger 반복이므로, 별도 스토어를 만들지 않고 여기를 읽는다
# (#464 작업 범위: "새 중복 버킷은 만들지 않는다").
#
# 위 airflow_batch 바인딩과 같은 조건식을 쓴다 — bucket-wide artifact 권한을 실험
# 파드에 상속하지 않고 스냅샷 prefix로만 한정한다. **read만 부여한다**: 게시는
# airflow_batch의 objectCreator가 담당하고, 실험 Job은 입력을 소비만 한다.
#
# 조건부 IAM은 object 단위로 평가되므로 objects.get은 prefix로 좁혀지지만
# objects.list는 bucket resource에 대해 평가돼 조건이 성립하지 않는다. 즉 목록 조회는
# 되지 않는데, 애플리케이션이 content-addressed 경로를 직접 지정해 읽으므로 문제없다.
resource "google_storage_bucket_iam_member" "experiment_job_mlflow_training_snapshot_viewer" {
  bucket = google_storage_bucket.mlflow_artifacts.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.experiment_job.email}"

  condition {
    title       = "training-snapshot-prefix-read-experiment-job"
    description = "Allow experiment executor Jobs to read published training snapshots only."
    expression  = "resource.name.startsWith('projects/_/buckets/${google_storage_bucket.mlflow_artifacts.name}/objects/${local.mlflow_training_snapshot_prefix}')"
  }
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
