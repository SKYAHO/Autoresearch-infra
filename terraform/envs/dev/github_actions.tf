# #121/#157 GitHub Actions WIF → GAR push
# 배포 리포별 GitHub Actions가 WIF 경유로 가장할 전용 SA와 GAR repository
# 쓰기 권한. bootstrap WIF provider의 attribute_condition도 각 리포를
# 허용하도록 확장되어야 한다(terraform/bootstrap).

locals {
  github_wif_pool_name       = "projects/${data.google_project.current.number}/locations/global/workloadIdentityPools/autoresearch-github"
  gar_pusher_sa_name         = "${local.resource_prefix}-gar-pusher"
  application_pusher_sa_name = "${local.resource_prefix}-app-pusher"
  airflow_deployer_sa_name   = "${local.resource_prefix}-airflow-cd"
}

# GitHub Actions 가 WIF 경유로 가장하는 service account (이미지 push 전용).
resource "google_service_account" "gar_pusher" {
  account_id   = local.gar_pusher_sa_name
  display_name = "Autoresearch dev GitHub Actions GAR pusher SA"
  description  = "Impersonated by Autoresearch-airflow GitHub Actions via WIF to push images to GAR."
}

# Autoresearch-airflow 리포 + 승인 ref만 이 SA 가장 허용 (#175).
# repository 단독이 아니라 repository_ref(repo@ref) 조합으로 제한해
# 임의 브랜치 workflow의 가장을 차단한다.
resource "google_service_account_iam_member" "gar_pusher_wi" {
  service_account_id = google_service_account.gar_pusher.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${local.github_wif_pool_name}/attribute.repository_ref/SKYAHO/Autoresearch-airflow@${var.airflow_deploy_ref}"
}

# GAR repository 쓰기 권한 (batch/airflow 이미지 push).
resource "google_artifact_registry_repository_iam_member" "gar_pusher_ar_writer" {
  repository = google_artifact_registry_repository.dev.id
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.gar_pusher.email}"
}

# Autoresearch 애플리케이션 이미지 push 전용 service account.
# Airflow 이미지 배포 계정과 분리해 저장소 간 권한 전이를 막는다.
resource "google_service_account" "application_pusher" {
  account_id   = local.application_pusher_sa_name
  display_name = "Autoresearch dev application GAR pusher SA"
  description  = "Impersonated by Autoresearch GitHub Actions via WIF to push application images to GAR."
}

# 정확한 Autoresearch release workflow만 애플리케이션 이미지 push SA 가장 허용.
# release event의 ref는 tag이므로 repository_ref 대신 workflow_ref를 사용한다.
resource "google_service_account_iam_member" "application_pusher_wi" {
  service_account_id = google_service_account.application_pusher.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${local.github_wif_pool_name}/attribute.workflow_ref/${var.application_release_workflow_ref}"
}

# 기존 dev GAR repository에만 애플리케이션 이미지 쓰기를 허용한다.
resource "google_artifact_registry_repository_iam_member" "application_pusher_ar_writer" {
  repository = google_artifact_registry_repository.dev.id
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.application_pusher.email}"
}

# Autoresearch-airflow main의 Helm 배포 전용 service account.
resource "google_service_account" "airflow_deployer" {
  account_id   = local.airflow_deployer_sa_name
  display_name = "Autoresearch dev Airflow GKE deployer SA"
  description  = "Impersonated by Autoresearch-airflow GitHub Actions to deploy the Airflow Helm release."
}

resource "google_service_account_iam_member" "airflow_deployer_wi" {
  service_account_id = google_service_account.airflow_deployer.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${local.github_wif_pool_name}/attribute.repository_ref/SKYAHO/Autoresearch-airflow@${var.airflow_deploy_ref}"
}

# GKE DNS endpoint 접속과 cluster metadata 조회만 GCP IAM으로 허용한다.
# 실제 변경 권한은 airflow namespace의 Kubernetes RoleBinding이 통제한다.
resource "google_project_iam_member" "airflow_deployer_cluster_viewer" {
  project = var.project_id
  role    = "roles/container.clusterViewer"
  member  = "serviceAccount:${google_service_account.airflow_deployer.email}"
}
