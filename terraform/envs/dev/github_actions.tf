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

# #307 admin root CI apply 전용 service account.
# admin-apply.yml 워크플로우가 WIF로 가장해 terraform/admin/*-k8s를 apply한다.
# argocd-k8s는 CRD/ClusterRole/ClusterRoleBinding을 설치하므로 K8s cluster-admin이
# 불가피하다. GKE는 roles/container.admin에 cluster-admin RBAC를 자동 매핑한다.
# 광범위한 권한이므로 (1) 전용 SA, (2) admin-apply.yml@main repo@ref 제한,
# (3) GitHub Environment 승인 게이트 3중으로 사용을 제한한다. clusterViewer +
# scoped ClusterRoleBinding 하드닝은 후속(#307 참고).
resource "google_service_account" "admin_apply" {
  account_id   = "${local.resource_prefix}-admin-apply"
  display_name = "Autoresearch dev admin root CI apply SA"
  description  = "Impersonated by Autoresearch-infra admin-apply.yml via WIF to apply terraform/admin/*-k8s roots."
}

# admin-apply.yml@main workflow_ref만 이 SA 가장 허용. 임의 브랜치/다른
# workflow의 가장을 차단한다(application_pusher와 동일 패턴).
resource "google_service_account_iam_member" "admin_apply_wi" {
  service_account_id = google_service_account.admin_apply.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${local.github_wif_pool_name}/attribute.workflow_ref/${var.admin_apply_workflow_ref}"
}

# GKE 접속 + K8s cluster-admin(자동 매핑). CRD/ClusterRole 설치가 필요한
# admin root apply의 불가피한 요건.
resource "google_project_iam_member" "admin_apply_container_admin" {
  project = var.project_id
  role    = "roles/container.admin"
  member  = "serviceAccount:${google_service_account.admin_apply.email}"
}

# Terraform state 읽기/쓰기(apply는 state를 갱신하므로 objectAdmin).
resource "google_storage_bucket_iam_member" "admin_apply_state" {
  bucket = "autoresearch-dev-tfstate"
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.admin_apply.email}"
}

# admin root의 versions.tf가 쓰는 data.google_container_cluster는 클러스터를 읽을 때
# node pool의 InstanceGroupManager까지 조회하는데, 이는 compute.* 권한이라
# container.admin(container.*)으로는 부족하다(compute.instanceGroupManagers.list
# 403). 읽기 전용 compute viewer로 보완한다. 하드닝 시 compute
# instanceGroupManagers list/get만 담은 커스텀 role로 축소 가능(#307 후속).
resource "google_project_iam_member" "admin_apply_compute_viewer" {
  project = var.project_id
  role    = "roles/compute.viewer"
  member  = "serviceAccount:${google_service_account.admin_apply.email}"
}
