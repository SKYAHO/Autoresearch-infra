# #129 Feast Online Store Redis.
# 기존 Private Service Access 연결과 대역을 Cloud SQL과 공유한다.
# AUTH와 TLS는 보안 경계이므로 변수 토글 없이 상시 활성화한다.

resource "google_redis_instance" "online_store" {
  name           = local.redis_instance_name
  display_name   = "Autoresearch dev Feast Online Store"
  tier           = var.redis_tier
  memory_size_gb = var.redis_memory_size_gb
  region         = var.region
  location_id    = var.zone

  redis_version = var.redis_version

  authorized_network      = google_compute_network.dev.id
  connect_mode            = "PRIVATE_SERVICE_ACCESS"
  auth_enabled            = true
  transit_encryption_mode = "SERVER_AUTHENTICATION"

  deletion_protection = var.redis_deletion_protection

  maintenance_policy {
    description = "Sunday 17:00 UTC (Monday 02:00 KST) dev maintenance window"

    weekly_maintenance_window {
      day = "SUNDAY"

      start_time {
        hours   = 17
        minutes = 0
        seconds = 0
        nanos   = 0
      }
    }
  }

  depends_on = [google_service_networking_connection.private_sql]
}
