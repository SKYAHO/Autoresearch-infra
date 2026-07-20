# #238 코드 아카이브 배포 파이프라인 인프라.
# GitHub Actions(Autoresearch code-archive.yml)가 main 머지/dispatch 시 코드
# tar.gz를 이 버킷에 올리고 latest.txt를 갱신하며, GKE autoresearch-app 파드가
# 시작 시 아카이브를 내려받아 실행한다. 앱 구현: SKYAHO/Autoresearch#180, #182.

# 코드 아카이브 전용 버킷. versioning 없음(#238), 삭제해도 git에서 재생성 가능한
# 배포 캐시라 prevent_destroy는 두지 않는다. 공개 접근은 차단.
resource "google_storage_bucket" "code_artifacts" {
  name                        = local.code_artifacts_bucket
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  labels = {
    data_class = "artifact"
    purpose    = "code-artifacts"
  }
}

# GitHub Actions(Autoresearch)가 WIF로 가장해 아카이브를 업로드하는 전용 SA.
# 앱 이미지 push SA(application_pusher)와 분리해 권한 전이를 막는다.
resource "google_service_account" "code_uploader" {
  account_id   = local.code_uploader_sa_name
  display_name = "Autoresearch dev code archive uploader SA"
  description  = "Impersonated by Autoresearch GitHub Actions via WIF to upload code archives to GCS."
}

# 정확한 code-archive workflow(main)만 이 SA 가장 허용(#175/#221 관례:
# repository 단독이 아니라 workflow_ref로 임의 브랜치·워크플로우 가장 차단).
# push(main)·workflow_dispatch(main) 모두 workflow_ref가 동일해 단일 바인딩으로 충분.
resource "google_service_account_iam_member" "code_uploader_wi" {
  service_account_id = google_service_account.code_uploader.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${local.github_wif_pool_name}/attribute.workflow_ref/${var.code_uploader_workflow_ref}"
}

# 업로더는 이 버킷에만 objectAdmin. latest.txt 덮어쓰기가 필요해 objectViewer로는
# 부족하다. 프로젝트 수준 권한은 부여하지 않는다(resource-level 최소권한).
resource "google_storage_bucket_iam_member" "code_uploader_object_admin" {
  bucket = google_storage_bucket.code_artifacts.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.code_uploader.email}"
}

# GKE autoresearch-app 파드(gke_app GSA)는 이 버킷 read만(아카이브 다운로드).
resource "google_storage_bucket_iam_member" "code_artifacts_app_viewer" {
  bucket = google_storage_bucket.code_artifacts.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.gke_app.email}"
}

# #263 Feast materialize DAG. KubernetesPodOperator가 KSA airflow/autoresearch-batch로
# 띄우는 Feast 전용 이미지의 entrypoint가 code/latest.txt와 code/<sha>.tar.gz를 읽는다.
# gke_app과 동일하게 이 버킷 read만 부여하고 write(objectAdmin)는 업로더 SA에만 남긴다.
resource "google_storage_bucket_iam_member" "code_artifacts_airflow_batch_viewer" {
  bucket = google_storage_bucket.code_artifacts.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.airflow_batch.email}"
}
