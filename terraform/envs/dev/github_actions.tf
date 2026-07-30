# #121/#157 GitHub Actions WIF → GAR push
# 배포 리포별 GitHub Actions가 WIF 경유로 가장할 전용 SA와 GAR repository
# 쓰기 권한. bootstrap WIF provider의 attribute_condition도 각 리포를
# 허용하도록 확장되어야 한다(terraform/bootstrap).

locals {
  github_wif_pool_name       = "projects/${data.google_project.current.number}/locations/global/workloadIdentityPools/autoresearch-github"
  gar_pusher_sa_name         = "${local.resource_prefix}-gar-pusher"
  application_pusher_sa_name = "${local.resource_prefix}-app-pusher"
  airflow_deployer_sa_name   = "${local.resource_prefix}-airflow-cd"

  # GSA account_id는 6~30자다. resource_prefix가 16자(`autoresearch-dev`)라
  # 접미사 예산은 선행 `-` 포함 14자뿐이어서 `-feast-apply-dev`(16자)는 들어가지
  # 않는다(#424 최초 구성의 plan 실패, #433에서 수정).
  # `airflow_deployer_sa_name`이 `-airflow-deployer`를
  # `-airflow-cd`로 줄인 것과 같은 방식으로 역할어를 생략하고, "Feast apply"
  # 용도는 display_name/description에 남긴다. 이 제한은 provider가 plan 단계에서
  # 검증하므로 validate만으로는 걸러지지 않는다.
  feast_apply_dev_sa_name  = "${local.resource_prefix}-feast-dev"
  feast_apply_prod_sa_name = "${local.resource_prefix}-feast-prod"
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

# #451 1단계: 통합 진입점 apply.yml 바인딩 추가. 옛 바인딩과 공존하는 이 구간이
# 있어야 workflow 교체(2단계)를 CI로 수행할 수 있다. 3단계에서 옛 것을 제거한다.
resource "google_service_account_iam_member" "admin_apply_wi_unified" {
  service_account_id = google_service_account.admin_apply.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${local.github_wif_pool_name}/attribute.workflow_ref/${var.apply_workflow_ref}"
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
  bucket = "autoresearch-503903-dev-tfstate"
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
# #341 dev root(terraform/envs/dev) CI apply 전용 service account.
# dev-apply.yml이 WIF로 가장해 dev root를 plan/apply한다. dev root는 프로젝트
# IAM·SA·WIF 바인딩까지 관리하므로 이 SA는 사실상 프로젝트 최강 자격증명이다.
# 통제 3중: (1) 전용 SA, (2) dev-apply.yml@main workflow_ref 제한, (3) GitHub
# Environment(dev-apply) 승인 게이트. admin-apply와 SA를 분리해 최강 권한의
# 사용 경로를 이 workflow 하나로 고정한다(설계:
# docs/superpowers/specs/2026-07-24-dev-apply-gated-ci-design.md).
resource "google_service_account" "dev_apply" {
  account_id   = "${local.resource_prefix}-dev-apply"
  display_name = "Autoresearch dev root CI apply SA"
  description  = "Impersonated by Autoresearch-infra dev-apply.yml via WIF to apply terraform/envs/dev."
}

resource "google_service_account_iam_member" "dev_apply_wi" {
  service_account_id = google_service_account.dev_apply.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${local.github_wif_pool_name}/attribute.workflow_ref/${var.dev_apply_workflow_ref}"
}

# #451 1단계: 통합 진입점 apply.yml 바인딩 추가(위 admin_apply_wi_unified와 동일
# 취지). 이 SA는 프로젝트 최강 자격이므로, 진입점 단일화 후 통제는 (1) 전용 SA
# 유지, (2) apply.yml@main ref 제한, (3) Environment(apply) 승인 게이트로 남는다
# — 파일 단위 분리가 사라지는 것을 #451에서 명시적으로 수용한 결과다.
resource "google_service_account_iam_member" "dev_apply_wi_unified" {
  service_account_id = google_service_account.dev_apply.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${local.github_wif_pool_name}/attribute.workflow_ref/${var.apply_workflow_ref}"
}

# dev root가 관리하는 리소스 타입 전수 스캔 기준 role 열거(#341 spec 표).
# owner/editor 단일 부여 대신 열거해 크기를 명시한다. 부족분은 403-driven으로
# 실측 보완(#310 compute.viewer 전례)하고 spec에 반영한다.
resource "google_project_iam_member" "dev_apply_roles" {
  for_each = toset([
    "roles/compute.networkAdmin",                     # VPC/subnet/router/NAT/route/firewall/address
    "roles/compute.instanceAdmin.v1",                 # bastion GCE
    "roles/compute.viewer",                           # GKE data source IGM 조회(#310)
    "roles/container.clusterAdmin",                   # cluster/node pool(K8s object 없음 → container.admin 불요)
    "roles/iam.serviceAccountAdmin",                  # SA 15종 + SA IAM
    "roles/iam.serviceAccountUser",                   # bastion·Cloud Run SA attach(actAs)
    "roles/resourcemanager.projectIamAdmin",          # project IAM member 21건
    "roles/iam.roleAdmin",                            # custom role
    "roles/storage.admin",                            # bucket 8 + bucket IAM 33 + tfstate
    "roles/bigquery.admin",                           # dataset/table/connection/dataset IAM
    "roles/cloudsql.admin",                           # instance/db/user
    "roles/redis.admin",                              # Redis Cluster
    "roles/secretmanager.admin",                      # secret/version/secret IAM
    "roles/artifactregistry.admin",                   # repo + repo IAM
    "roles/dns.admin",                                # zone/record
    "roles/cloudkms.admin",                           # KMS keyring/key(#132 vault)
    "roles/run.admin",                                # Cloud Run v2 + service IAM
    "roles/servicenetworking.networksAdmin",          # Cloud SQL PSA peering
    "roles/networkconnectivity.consumerNetworkAdmin", # Redis PSC service connection policy
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.dev_apply.email}"
}

# #314 gke-team-access(팀원 프로젝트/BigQuery/AR IAM)는 CI apply에서 제외한다 —
# 그 root를 apply하려면 apply SA에 projectIamAdmin + bigquery.admin +
# artifactregistry.admin까지 필요해 과도한 escalation이 된다. 사람 IAM은 로컬
# break-glass로 유지하고, apply SA는 K8s admin root 범위(container.admin +
# compute.viewer + state)로만 둔다. (이전 #312의 projectIamAdmin 부여는 회수됨.)

# #424 GitHub Environment와 같은 이름의 전용 GSA를 사용한다. dev/prod의
# registry, offline store, Redis 접근을 서로 섞지 않는다.
resource "google_service_account" "feast_apply_dev" {
  account_id   = local.feast_apply_dev_sa_name
  display_name = "Autoresearch dev Feast apply development SA"
  description  = "Impersonated from the dev GitHub Environment to run Feast apply against dev-only resources."
}

resource "google_service_account" "feast_apply_prod" {
  account_id   = local.feast_apply_prod_sa_name
  display_name = "Autoresearch dev Feast apply production SA"
  description  = "Impersonated from the prod GitHub Environment to run Feast apply against production Feast resources."
}

# provider 조건이 repository, environment, workflow_ref를 함께 강제한다. IAM
# member는 OR로 평가되므로 workflow_ref principalSet을 별도로 추가하면 안 된다.
resource "google_service_account_iam_member" "feast_apply_dev_wi" {
  service_account_id = google_service_account.feast_apply_dev.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${local.github_wif_pool_name}/attribute.environment/dev"
}

resource "google_service_account_iam_member" "feast_apply_prod_wi" {
  service_account_id = google_service_account.feast_apply_prod.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${local.github_wif_pool_name}/attribute.environment/prod"
}

# Feast GCS registry client는 bucket.reload()에 storage.buckets.get이 필요하다.
# objectAdmin에 없는 이 권한만 legacyBucketReader로 보강한다.
resource "google_storage_bucket_iam_member" "feast_apply_dev_registry_object_admin" {
  bucket = google_storage_bucket.feast_registry_dev.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.feast_apply_dev.email}"
}

resource "google_storage_bucket_iam_member" "feast_apply_dev_registry_bucket_reader" {
  bucket = google_storage_bucket.feast_registry_dev.name
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${google_service_account.feast_apply_dev.email}"
}

resource "google_storage_bucket_iam_member" "feast_apply_dev_staging_object_admin" {
  bucket = google_storage_bucket.feast_staging_dev.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.feast_apply_dev.email}"
}

resource "google_storage_bucket_iam_member" "feast_apply_dev_staging_bucket_reader" {
  bucket = google_storage_bucket.feast_staging_dev.name
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${google_service_account.feast_apply_dev.email}"
}

resource "google_storage_bucket_iam_member" "feast_apply_prod_registry_object_admin" {
  bucket = google_storage_bucket.feast_registry.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.feast_apply_prod.email}"
}

resource "google_storage_bucket_iam_member" "feast_apply_prod_registry_bucket_reader" {
  bucket = google_storage_bucket.feast_registry.name
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${google_service_account.feast_apply_prod.email}"
}

resource "google_storage_bucket_iam_member" "feast_apply_prod_staging_object_admin" {
  bucket = google_storage_bucket.feast_staging.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.feast_apply_prod.email}"
}

resource "google_storage_bucket_iam_member" "feast_apply_prod_staging_bucket_reader" {
  bucket = google_storage_bucket.feast_staging.name
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${google_service_account.feast_apply_prod.email}"
}

# feast apply source validation에는 tables.get만 필요하므로 각 환경의 dataset에
# metadataViewer만 부여한다.
resource "google_bigquery_dataset_iam_member" "feast_apply_dev_offline_store_metadata_viewer" {
  dataset_id = google_bigquery_dataset.feast_offline_store_dev.dataset_id
  role       = "roles/bigquery.metadataViewer"
  member     = "serviceAccount:${google_service_account.feast_apply_dev.email}"
}

resource "google_bigquery_dataset_iam_member" "feast_apply_prod_offline_store_metadata_viewer" {
  dataset_id = google_bigquery_dataset.feast_offline_store.dataset_id
  role       = "roles/bigquery.metadataViewer"
  member     = "serviceAccount:${google_service_account.feast_apply_prod.email}"
}

# Task 3가 만들 dev/prod namespace의 KSA만 같은 환경 GSA를 가장할 수 있다.
resource "google_service_account_iam_member" "feast_apply_dev_ksa_wi" {
  service_account_id = google_service_account.feast_apply_dev.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.feast_apply_workload_identity_principals.dev}"

  depends_on = [google_container_cluster.dev]
}

resource "google_service_account_iam_member" "feast_apply_prod_ksa_wi" {
  service_account_id = google_service_account.feast_apply_prod.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.feast_apply_workload_identity_principals.prod}"

  depends_on = [google_container_cluster.dev]
}

# GKE endpoint와 cluster metadata 조회는 두 환경에 필요하다. Job 권한은 Task 3의
# 환경별 namespace RoleBinding이 별도로 제한한다.
resource "google_project_iam_member" "feast_apply_dev_cluster_viewer" {
  project = var.project_id
  role    = "roles/container.clusterViewer"
  member  = "serviceAccount:${google_service_account.feast_apply_dev.email}"
}

resource "google_project_iam_member" "feast_apply_prod_cluster_viewer" {
  project = var.project_id
  role    = "roles/container.clusterViewer"
  member  = "serviceAccount:${google_service_account.feast_apply_prod.email}"
}
