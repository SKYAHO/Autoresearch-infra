locals {
  # 기본값은 Cloud Build가 자동 생성하는 <project_id>_cloudbuild 버킷.
  cloud_build_staging_bucket = coalesce(var.cloud_build_staging_bucket, "${var.project_id}_cloudbuild")
}

# Team member access is intentionally separated from terraform/envs/dev.
# This keeps personal email addresses and off-boarding churn out of PR plan comments.
#
# #45: role을 clusterViewer → container.viewer로 확대. DNS 기반 컨트롤 플레인
# 엔드포인트 접속에 필요한 container.clusters.connect가 clusterViewer에는 없고
# viewer(읽기 전용)에 포함되기 때문. GCP 리소스 변경 권한은 없다.
# 주의(의도된 결정): viewer는 IAM→k8s 매핑으로 클러스터 전역 k8s 오브젝트
# 읽기(secrets 제외)도 부여한다. 소규모 팀의 상호 가시성을 위해 전역 읽기를
# 허용하는 팀 방침이며, 쓰기/namespace 작업 권한은 여전히 RBAC(#32)로만 부여된다.
resource "google_project_iam_member" "gke_kubectl_users" {
  for_each = var.team_member_emails

  project = var.project_id
  role    = "roles/container.viewer"
  member  = "user:${each.value}"
}

# #215 팀원의 BigQuery 작업 실행 권한과 dataset별 데이터 편집 권한.
# jobUser는 BigQuery job을 프로젝트에 생성하는 데 필요하고, dataEditor는 아래 두
# dataset으로만 제한한다. 프로젝트 수준 Data Editor/Editor/Owner는 부여하지 않는다.
resource "google_project_iam_member" "team_bigquery_job_users" {
  for_each = var.team_member_emails

  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "user:${each.value}"
}

resource "google_bigquery_dataset_iam_member" "team_bigquery_analytics_data_editors" {
  for_each = var.team_member_emails

  project    = var.project_id
  dataset_id = var.bigquery_analytics_dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "user:${each.value}"
}

resource "google_bigquery_dataset_iam_member" "team_bigquery_feast_data_editors" {
  for_each = var.team_member_emails

  project    = var.project_id
  dataset_id = var.bigquery_feast_offline_store_dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "user:${each.value}"
}

# #47 Bastion IAP 터널 접속 3종. 모두 읽기/접속용이며 리소스 변경 권한 없음.
# - iap.tunnelResourceAccessor: IAP TCP forwarding 통과
# - compute.osLogin: SSH 키 배포 없이 IAM 기반 SSH 로그인
# - compute.viewer: gcloud compute ssh가 요구하는 instance 조회
resource "google_project_iam_member" "bastion_iap_tunnel_users" {
  for_each = var.team_member_emails

  project = var.project_id
  role    = "roles/iap.tunnelResourceAccessor"
  member  = "user:${each.value}"
}

resource "google_project_iam_member" "bastion_oslogin_users" {
  for_each = var.team_member_emails

  project = var.project_id
  role    = "roles/compute.osLogin"
  member  = "user:${each.value}"
}

resource "google_project_iam_member" "bastion_compute_viewer_users" {
  for_each = var.team_member_emails

  project = var.project_id
  role    = "roles/compute.viewer"
  member  = "user:${each.value}"
}

# #185/#256 임시: 학습 이미지(autoresearch-training)를 GAR에 첫 수동 push하도록
# autoresearch-dev-docker 저장소 범위 writer만 부여한다. 프로젝트 수준이 아니라
# 저장소 IAM으로 한정하고, 대상은 team_member_emails와 분리한 전용 변수로 둔다.
# 회수: training_image_ar_writer_emails를 비우고 apply. 항구적 push 경로는 개인
# 계정이 아니라 application_pusher WIF SA(앱 CI, #185 본작업)이다.
resource "google_artifact_registry_repository_iam_member" "training_image_temp_writers" {
  for_each = var.training_image_ar_writer_emails

  project    = var.project_id
  location   = var.region
  repository = var.artifact_registry_repository_id
  role       = "roles/artifactregistry.writer"
  member     = "user:${each.value}"
}

# #266 배포된 이미지 digest 확인용 read 권한. 앱 저장소 release 파이프라인 문서가
# `gcloud artifacts docker images list/describe`를 표준 운영 절차로 안내하는데 사람
# 계정에 read 권한이 없었다. 저장소 범위로만 부여하고 push(writer)는 WIF SA와
# training_image_ar_writer_emails에만 남긴다.
resource "google_artifact_registry_repository_iam_member" "team_ar_readers" {
  for_each = var.team_member_emails

  project    = var.project_id
  location   = var.region
  repository = var.artifact_registry_repository_id
  role       = "roles/artifactregistry.reader"
  member     = "user:${each.value}"
}

# #266 Feast 이미지를 로컬 Docker 없이 빌드하는 `gcloud builds submit` 경로.
# builds.editor는 build 생성·조회 권한이며, source 업로드에는 Cloud Build 자동 생성
# staging bucket(<project_id>_cloudbuild) 쓰기가 함께 필요하다(버킷 범위로만 부여).
#
# ⚠️ 권한 경계 주의: build는 기본 compute SA로 실행되고, 그 SA에는 dev GAR 저장소
# writer가 부여돼 있다(terraform/envs/dev/cloud_build.tf). 따라서 builds.editor는
# "빌드를 통한 간접 이미지 push 경로"를 함께 여는 셈이며, 사람 계정에 직접 부여한
# artifactregistry는 reader뿐이라는 점과 구분해서 이해해야 한다. 이 경로를 막으려면
# build 전용 SA를 분리하고 기본 compute SA의 writer를 걷어야 한다(후속 과제).
resource "google_project_iam_member" "team_cloud_build_editors" {
  for_each = var.team_member_emails

  project = var.project_id
  role    = "roles/cloudbuild.builds.editor"
  member  = "user:${each.value}"
}

resource "google_storage_bucket_iam_member" "team_cloud_build_staging_writers" {
  for_each = var.team_member_emails

  bucket = local.cloud_build_staging_bucket
  role   = "roles/storage.objectAdmin"
  member = "user:${each.value}"
}

# #266 Cloud SQL 인스턴스 상태·private IP 조회. 데이터 접근 권한은 아니며
# (client/admin 아님), 접속은 여전히 GKE 내부 경로와 DB 계정으로만 가능하다.
resource "google_project_iam_member" "team_cloudsql_viewers" {
  for_each = var.team_member_emails

  project = var.project_id
  role    = "roles/cloudsql.viewer"
  member  = "user:${each.value}"
}

# #266 Airflow metadata DB 비밀번호 조회. Airflow 저장소 runbook의 Secret 생성·교체
# 절차가 project owner 계정에만 가능해 병목이었다. secret 하나의 resource-level
# IAM으로만 부여하고 프로젝트 수준 Secret Manager 역할은 주지 않는다.
resource "google_secret_manager_secret_iam_member" "team_db_password_accessors" {
  for_each = var.team_member_emails

  project   = var.project_id
  secret_id = var.db_password_secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "user:${each.value}"
}
