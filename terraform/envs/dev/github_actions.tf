# #121/#157 GitHub Actions WIF → GAR push
# 배포 리포별 GitHub Actions가 WIF 경유로 가장할 전용 SA와 GAR repository
# 쓰기 권한. bootstrap WIF provider의 attribute_condition도 각 리포를
# 허용하도록 확장되어야 한다(terraform/bootstrap).

locals {
  github_wif_pool_name       = "projects/${data.google_project.current.number}/locations/global/workloadIdentityPools/autoresearch-github"
  gar_pusher_sa_name         = "${local.resource_prefix}-gar-pusher"
  application_pusher_sa_name = "${local.resource_prefix}-app-pusher"
  airflow_deployer_sa_name   = "${local.resource_prefix}-airflow-cd"
  code_uploader_sa_name      = "${local.resource_prefix}-code-uploader"
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

# 정확한 Autoresearch release workflow의 workflow_dispatch(main)만
# 애플리케이션 이미지 push SA 가장 허용. #221의 release:published(tag)는 별도
# event + workflow path 바인딩으로 추가해, 임의 ref workflow_dispatch를 막는다.
resource "google_service_account_iam_member" "application_pusher_wi" {
  service_account_id = google_service_account.application_pusher.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${local.github_wif_pool_name}/attribute.workflow_ref/${var.application_release_workflow_ref}"
}

# release:published(tag)에서만 같은 release.yml의 SA 가장 허용. GitHub release
# 이벤트는 default branch의 workflow 파일만 실행하므로, tag ref를 열어두지 않고
# event_name과 workflow 경로를 함께 검증한다.
resource "google_service_account_iam_member" "application_pusher_release_wi" {
  service_account_id = google_service_account.application_pusher.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${local.github_wif_pool_name}/attribute.workflow_event_path/${var.application_release_workflow_event_path}"
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

# #238 코드 아카이브 업로더 SA.
# Autoresearch code-archive 워크플로우가 WIF로 가장해 코드 아카이브를 GCS에 올린다.
# 이미지 push 계정과 분리해 저장소 간 권한 전이를 막는다.
resource "google_service_account" "code_uploader" {
  account_id   = local.code_uploader_sa_name
  display_name = "Autoresearch dev code archive uploader SA"
  description  = "Impersonated by Autoresearch GitHub Actions via WIF to upload code archives to the code-artifacts bucket."
}

# 정확한 Autoresearch code-archive 워크플로우(main)만 이 SA 가장을 허용한다.
# application_pusher와 동일하게 repository가 아니라 workflow_ref(파일@ref)로 제한해
# 같은 저장소의 임의 브랜치·다른 워크플로우가 업로더 권한을 얻지 못하게 한다.
resource "google_service_account_iam_member" "code_uploader_wi" {
  service_account_id = google_service_account.code_uploader.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${local.github_wif_pool_name}/attribute.workflow_ref/${var.code_uploader_workflow_ref}"
}

# code-artifacts 버킷에만 objectAdmin을 부여한다. latest.txt를 덮어써야 하므로
# objectCreator로는 부족하고, 프로젝트 전역이 아니라 이 버킷 단위로 제한한다.
resource "google_storage_bucket_iam_member" "code_uploader_object_admin" {
  bucket = google_storage_bucket.code_artifacts.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.code_uploader.email}"
}
