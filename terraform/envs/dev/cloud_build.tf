# Autoresearch-airflow Cloud Build의 Airflow 이미지 build/push 경로.
# API enablement remains manual; this file only manages least-privilege IAM.
data "google_project" "current" {
  project_id = var.project_id
}

resource "google_artifact_registry_repository_iam_member" "cloud_build_compute_ar_writer" {
  repository = google_artifact_registry_repository.dev.id
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${local.cloud_build_compute_service_account_email}"
}

resource "google_storage_bucket_iam_member" "cloud_build_compute_bucket_object_viewer" {
  bucket = local.cloud_build_bucket_name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${local.cloud_build_compute_service_account_email}"
}

resource "google_project_iam_member" "cloud_build_compute_logging" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${local.cloud_build_compute_service_account_email}"
}
