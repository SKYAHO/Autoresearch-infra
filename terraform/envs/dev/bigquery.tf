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
