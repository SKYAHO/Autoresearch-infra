# #102 Elasticsearch GCS snapshot 기반. ES 설치/repository 등록은
# terraform/admin/elastic-k8s가 담당하고, dev root는 GCP 측(bucket, GSA,
# WI)만 관리한다 — vault.tf(#132)와 동일 분리.

resource "google_storage_bucket" "es_snapshots" {
  name                        = local.es_snapshot_bucket_name
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  # 주의: age 기반 lifecycle을 두지 않는다. ES snapshot은 증분(세그먼트
  # 공유) 구조라 오래된 객체를 나이로 지우면 최신 snapshot까지 손상된다.
  # 보관 정리는 SLM retention(expire_after 7d)이 ES API로 수행한다
  # (#96 spec의 lifecycle 문구를 이 근거로 정정).

  soft_delete_policy {
    retention_duration_seconds = 0
  }
}

# ES snapshot 전용 GSA. repository-gcs가 Workload Identity(ADC)로 사용한다
# — SA key 미발급 원칙 유지.
resource "google_service_account" "es_snapshot" {
  account_id   = local.es_snapshot_sa_name
  display_name = "Autoresearch dev Elasticsearch snapshot SA"
  description  = "repository-gcs snapshot 전용. es-snapshots bucket 권한만 보유."
}

resource "google_service_account_iam_member" "es_snapshot_wi" {
  service_account_id = google_service_account.es_snapshot.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.es_workload_identity_principal}"

  depends_on = [google_container_cluster.dev]
}

# bucket 단위 최소 권한: 객체 CRUD(objectAdmin) + repository verify가
# 요구하는 buckets.get(legacyBucketReader). 프로젝트 수준 부여 없음.
resource "google_storage_bucket_iam_member" "es_snapshot_object_admin" {
  bucket = google_storage_bucket.es_snapshots.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.es_snapshot.email}"
}

resource "google_storage_bucket_iam_member" "es_snapshot_bucket_reader" {
  bucket = google_storage_bucket.es_snapshots.name
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${google_service_account.es_snapshot.email}"
}
