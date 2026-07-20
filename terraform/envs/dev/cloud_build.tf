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

# #269 Cloud Build 전용 SA. 기본 compute SA는 프로젝트의 모든 build가 공유하는
# 주체라, 사람에게 cloudbuild.builds.editor를 주면(#266) 기본 SA의 GAR writer를
# 빌드로 빌려 쓰는 간접 push 경로가 열린다. build를 이 전용 SA로 실행시키면
# "빌드 제출 권한"과 "push 권한"을 분리할 수 있다.
resource "google_service_account" "cloud_build_builder" {
  account_id   = "${var.name_prefix}-cloud-build"
  display_name = "Cloud Build builder (dev images)"
  description  = "Dedicated Cloud Build runtime SA (#269). Team members submit builds via serviceAccountUser on this SA instead of the default compute SA."
}

# 이미지 push 대상은 dev 저장소 하나로 제한한다(프로젝트 수준 아님).
resource "google_artifact_registry_repository_iam_member" "cloud_build_builder_ar_writer" {
  repository = google_artifact_registry_repository.dev.id
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.cloud_build_builder.email}"
}

# source 아카이브 read와 build 로그 write. 사용자 지정 SA로 실행하는 build는
# 로그 대상을 명시해야 하므로 같은 staging 버킷의 logs/ 경로를 쓴다(버킷 범위).
resource "google_storage_bucket_iam_member" "cloud_build_builder_bucket_object_admin" {
  bucket = local.cloud_build_bucket_name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.cloud_build_builder.email}"
}

# objectAdmin에는 storage.buckets.get이 없어(#204 교훈) Cloud Build의 버킷 사용 가능
# 여부 사전 검사가 "does not have access to the bucket"으로 실패한다. 버킷 메타데이터
# 읽기를 같은 버킷 범위로만 추가한다.
resource "google_storage_bucket_iam_member" "cloud_build_builder_bucket_reader" {
  bucket = local.cloud_build_bucket_name
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${google_service_account.cloud_build_builder.email}"
}

resource "google_project_iam_member" "cloud_build_builder_logging" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.cloud_build_builder.email}"
}
