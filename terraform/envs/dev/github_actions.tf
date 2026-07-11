# #121 GitHub Actions (Autoresearch-airflow) WIF → GAR push
# 배포 리포 GitHub Actions가 WIF 경유로 가장할 SA + GAR repository 쓰기 권한.
# bootstrap WIF provider의 attribute_condition 이 SKYAHO/Autoresearch-airflow 를
# 허용하도록 확장되어야 한다 (terraform/bootstrap).

locals {
  github_wif_pool_name = "projects/${data.google_project.current.number}/locations/global/workloadIdentityPools/autoresearch-github"
  gar_pusher_sa_name   = "${local.resource_prefix}-gar-pusher"
}

# GitHub Actions 가 WIF 경유로 가장하는 service account (이미지 push 전용).
resource "google_service_account" "gar_pusher" {
  account_id   = local.gar_pusher_sa_name
  display_name = "Autoresearch dev GitHub Actions GAR pusher SA"
  description  = "Impersonated by Autoresearch-airflow GitHub Actions via WIF to push images to GAR."
}

# Autoresearch-airflow 리포만 이 SA 가장 허용 (principalSet 으로 리포 한정).
resource "google_service_account_iam_member" "gar_pusher_wi" {
  service_account_id = google_service_account.gar_pusher.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${local.github_wif_pool_name}/attribute.repository/SKYAHO/Autoresearch-airflow"
}

# GAR repository 쓰기 권한 (batch/airflow 이미지 push).
resource "google_artifact_registry_repository_iam_member" "gar_pusher_ar_writer" {
  repository = google_artifact_registry_repository.dev.id
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.gar_pusher.email}"
}
