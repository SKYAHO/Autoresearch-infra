# #27 dev proxy Cloud Run 서비스
# 앱 저장소(proxy/Dockerfile)의 proxy 컨테이너를 collector가 IAM 인증으로
# 호출하는 HTTP 엔드포인트로 배포한다. 트래픽이 하루 수 회 수준이라
# min instances 0 (유휴 비용 0) 기준으로 구성한다.
#
# - 이미지가 AR에 push되어 있어야 apply(revision 배포)가 성공한다.
#   빌드/push 절차는 docs/TERRAFORM_DEV.md 참조.
# - Airflow batch pod가 YouTube proxy를 호출할 수 있도록 batch 전용 GSA에
#   서비스 단위 run.invoker를 부여한다.
# - 추가 invoker는 var.proxy_invoker_members로 확장한다.

resource "google_service_account" "proxy" {
  account_id   = local.proxy_sa_name
  display_name = "Autoresearch dev proxy Cloud Run runtime SA"
}

resource "google_cloud_run_v2_service" "proxy" {
  name     = local.proxy_service_name
  location = var.region
  project  = var.project_id

  ingress             = var.proxy_ingress
  deletion_protection = var.proxy_deletion_protection

  template {
    service_account = google_service_account.proxy.email

    scaling {
      min_instance_count = 0
      max_instance_count = var.proxy_max_instances
    }

    containers {
      image = local.proxy_image

      ports {
        container_port = 8080
      }

      resources {
        limits = {
          cpu    = var.proxy_cpu
          memory = var.proxy_memory
        }
        cpu_idle = true
      }

      startup_probe {
        http_get {
          path = "/health"
          port = 8080
        }
      }

      liveness_probe {
        http_get {
          path = "/health"
          port = 8080
        }
      }
    }
  }
}

# public access 없음. YouTube 수집 batch pod 호출 주체에만 서비스 단위로 부여.
resource "google_cloud_run_v2_service_iam_member" "proxy_airflow_batch_invoker" {
  project  = var.project_id
  location = google_cloud_run_v2_service.proxy.location
  name     = google_cloud_run_v2_service.proxy.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.airflow_batch.email}"
}

# 후속 collector나 운영 주체가 추가될 때만 사용한다.
resource "google_cloud_run_v2_service_iam_member" "proxy_invokers" {
  for_each = toset(var.proxy_invoker_members)

  project  = var.project_id
  location = google_cloud_run_v2_service.proxy.location
  name     = google_cloud_run_v2_service.proxy.name
  role     = "roles/run.invoker"
  member   = each.value
}
