# #20 dev BigQuery analytics dataset
# GCS raw landing zone에서 정제/분석 가능한 데이터만 BigQuery table로 적재한다.
resource "google_bigquery_dataset" "analytics" {
  dataset_id                 = local.bigquery_dataset_id
  friendly_name              = "Autoresearch dev analytics"
  description                = "Structured dev analytics dataset for YouTube, user, action log, and persona data."
  location                   = var.bigquery_location
  delete_contents_on_destroy = var.bigquery_delete_contents_on_destroy

  labels = {
    data_class = "analytics"
    purpose    = "structured-analysis"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_bigquery_dataset_iam_member" "analytics_gke_app_data_editor" {
  dataset_id = google_bigquery_dataset.analytics.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.gke_app.email}"
}

resource "google_bigquery_dataset" "feast_offline_store" {
  dataset_id                 = local.feast_dataset_id
  friendly_name              = "Feast offline store"
  description                = "Dev BigQuery offline store dataset for Feast feature data."
  location                   = var.bigquery_location
  delete_contents_on_destroy = var.bigquery_delete_contents_on_destroy

  labels = {
    data_class = "feature-store"
    purpose    = "feast-offline-store"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_bigquery_dataset_iam_member" "feast_offline_store_gke_app_data_editor" {
  dataset_id = google_bigquery_dataset.feast_offline_store.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.gke_app.email}"
}

resource "google_project_iam_member" "gke_app_bigquery_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.gke_app.email}"
}

# #199 data lake 테이블 dt 파티션 고정
# 스키마/데이터는 SKYAHO/Autoresearch scripts/load_raw_to_bigquery.py가 소유하고
# (autodetect + WRITE_TRUNCATE), Terraform은 존재와 dt 일 단위 파티셔닝만 보장한다.
resource "google_bigquery_table" "data_lake_action_log" {
  dataset_id          = google_bigquery_dataset.feast_offline_store.dataset_id
  table_id            = "data_lake_action_log"
  description         = "GCS data_lake/action_log raw parquet 적재 테이블. dt 일 단위 파티션."
  deletion_protection = true

  time_partitioning {
    type  = "DAY"
    field = "dt"
  }

  # 파티션 필드는 생성 시점 스키마에 존재해야 한다. 이후 스키마는 적재 job이 관리한다.
  schema = jsonencode([
    {
      name        = "dt"
      type        = "DATE"
      mode        = "NULLABLE"
      description = "파티션 날짜 (GCS hive partition dt=* 복원 컬럼)"
    }
  ])

  labels = {
    data_class = "raw"
    purpose    = "data-lake-raw"
  }

  lifecycle {
    ignore_changes = [schema]
  }
}

resource "google_bigquery_table" "data_lake_youtube_trending_kr" {
  dataset_id          = google_bigquery_dataset.feast_offline_store.dataset_id
  table_id            = "data_lake_youtube_trending_kr"
  description         = "GCS data_lake/youtube_trending_kr raw parquet 적재 테이블. dt 일 단위 파티션."
  deletion_protection = true

  time_partitioning {
    type  = "DAY"
    field = "dt"
  }

  schema = jsonencode([
    {
      name        = "dt"
      type        = "DATE"
      mode        = "NULLABLE"
      description = "파티션 날짜 (GCS hive partition dt=* 복원 컬럼)"
    }
  ])

  labels = {
    data_class = "raw"
    purpose    = "data-lake-raw"
  }

  lifecycle {
    ignore_changes = [schema]
  }
}
