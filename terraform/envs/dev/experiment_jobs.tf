# Auto Research 실험 Job 결과 저장 경계. 실행 Job은 이 전용 버킷에 새 객체만
# 만들 수 있으며, 기존 객체 조회·변경·삭제와 다른 GCP 서비스 접근은 허용하지 않는다.
resource "google_storage_bucket" "experiment_results" {
  name                        = local.experiment_results_bucket_name
  location                    = var.experiment_results_bucket_location
  storage_class               = var.experiment_results_bucket_storage_class
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
      # 결과 live generation은 30일 후 archive한다. Job GSA는 overwrite/delete할 수
      # 없지만, 운영자 복구·정정으로 생긴 archived generation에는 별도 복구 창을 둔다.
      with_state = "LIVE"
      age        = var.experiment_results_object_retention_days
    }
  }

  lifecycle_rule {
    action {
      type = "Delete"
    }

    condition {
      # archived 시점부터 7일을 보존한 뒤 영구 삭제한다.
      with_state                 = "ARCHIVED"
      days_since_noncurrent_time = var.experiment_results_noncurrent_version_retention_days
    }
  }

  labels = {
    data_class = "experiment-results"
    purpose    = "auto-research"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_service_account" "experiment_job" {
  account_id   = local.experiment_job_sa_name
  display_name = "Auto Research dev experiment Job workload identity SA"
}

resource "google_service_account_iam_member" "experiment_job_wi" {
  service_account_id = google_service_account.experiment_job.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.experiment_job_workload_identity_principal}"

  depends_on = [google_container_cluster.dev]
}

# objectCreator는 storage.objects.delete가 없어 기존 객체를 덮어쓸 수 없다. 버킷
# versioning 여부와 별개로 실행 Job은 새 객체 생성만 가능하다. 앱은 create-if-absent
# precondition과 새 attempt id prefix로 논리적 경로 중복도 차단해야 하며, Job은 이전
# 결과를 읽거나 삭제할 수 없다.
resource "google_storage_bucket_iam_member" "experiment_job_object_creator" {
  bucket = google_storage_bucket.experiment_results.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.experiment_job.email}"
}
