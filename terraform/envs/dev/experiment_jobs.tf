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
      # 결과 live generation은 90일 후 archive한다. Job GSA는 overwrite/delete할 수
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
      # archived 시점부터 30일을 보존한 뒤 영구 삭제한다.
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

# objectCreator는 storage.objects.create만 준다. 다만 **이 버킷은 versioning이
# 켜져 있어 IAM만으로 overwrite가 막히지는 않는다** — GCS에서 delete 권한이
# 필요한 것은 versioning이 꺼진 버킷의 덮어쓰기뿐이고, versioning이 켜져 있으면
# 같은 경로 업로드가 새 generation을 만들고 이전 generation은 noncurrent로
# 남는다(삭제가 아니므로 create만으로 성립).
#
# 따라서 경로 재사용을 실제로 막는 것은 IAM이 아니라 앱의 create-if-absent
# precondition(`ifGenerationMatch=0`, 기존 live 객체가 있으면 HTTP 412)과 새
# attempt id prefix다. IAM이 보장하는 것은 "Job이 이전 결과를 읽거나 삭제할 수
# 없다"는 것(objectViewer·objectAdmin 미부여)이고, 감사 관점에서는 versioning이
# 이전 generation을 보존해 덮어쓰기가 발생해도 원본이 남는다.
resource "google_storage_bucket_iam_member" "experiment_job_object_creator" {
  bucket = google_storage_bucket.experiment_results.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.experiment_job.email}"
}

# 상태 API는 결과를 인증·감사 가능한 API 응답으로 제한해 제공하기 위해 읽기만 한다.
# 실행 Job과 달리 생성·변경·삭제 권한은 주지 않으며, 사용자에게 버킷 IAM을 직접
# 부여하거나 공개 URL을 만들지 않는다.
resource "google_storage_bucket_iam_member" "agent_orchestration_api_experiment_results_viewer" {
  bucket = google_storage_bucket.experiment_results.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.agent_orchestration_api.email}"
}
