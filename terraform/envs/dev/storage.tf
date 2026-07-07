# #18 dev 원본 데이터 GCS bucket
# YouTube raw, user raw, action log raw, persona raw 원본 전체를 prefix로 나눠 저장한다.
resource "google_storage_bucket" "raw_data" {
  name                        = local.raw_data_bucket_name
  location                    = var.raw_data_bucket_location
  storage_class               = var.raw_data_bucket_storage_class
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  versioning {
    enabled = true
  }

  soft_delete_policy {
    retention_duration_seconds = 0
  }

  lifecycle_rule {
    action {
      type = "Delete"
    }

    condition {
      with_state                 = "ARCHIVED"
      days_since_noncurrent_time = var.raw_data_noncurrent_version_retention_days
      matches_prefix             = values(local.raw_data_prefixes)
    }
  }

  labels = {
    data_class = "raw"
    purpose    = "original-data"
  }

  lifecycle {
    prevent_destroy = true
  }
}

# GKE app workload가 raw landing zone에 원본 파일을 적재/조회한다.
resource "google_storage_bucket_iam_member" "raw_data_gke_app_object_user" {
  bucket = google_storage_bucket.raw_data.name
  role   = "roles/storage.objectUser"
  member = "serviceAccount:${google_service_account.gke_app.email}"
}

# Feast registry 상태 파일을 저장한다.
resource "google_storage_bucket" "feast_registry" {
  name                        = local.feast_registry_bucket
  location                    = var.feast_bucket_location
  storage_class               = var.feast_bucket_storage_class
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  soft_delete_policy {
    retention_duration_seconds = 0
  }

  labels = {
    data_class = "metadata"
    purpose    = "feast-registry"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_storage_bucket_iam_member" "feast_registry_gke_app_object_user" {
  bucket = google_storage_bucket.feast_registry.name
  role   = "roles/storage.objectUser"
  member = "serviceAccount:${google_service_account.gke_app.email}"
}

# Feast materialization/load job의 임시 staging 파일을 저장한다.
resource "google_storage_bucket" "feast_staging" {
  name                        = local.feast_staging_bucket
  location                    = var.feast_bucket_location
  storage_class               = var.feast_bucket_storage_class
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  soft_delete_policy {
    retention_duration_seconds = 0
  }

  labels = {
    data_class = "staging"
    purpose    = "feast-staging"
  }
}

resource "google_storage_bucket_iam_member" "feast_staging_gke_app_object_user" {
  bucket = google_storage_bucket.feast_staging.name
  role   = "roles/storage.objectUser"
  member = "serviceAccount:${google_service_account.gke_app.email}"
}
