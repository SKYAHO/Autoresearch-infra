# #4 dev Cloud SQL (PostgreSQL, private IP)
# password: random 생성 → SQL user 주입. Secret Manager 저장은 secret_manager.tf(#5)에 구현.
# private IP: VPC 전용 대역 할당 후 servicenetworking peering.
# #129부터 같은 PSA 연결/대역을 Redis도 공유한다. 기존 state address는 유지한다.

resource "google_compute_global_address" "private_sql_range" {
  name          = "${local.resource_prefix}-private-sql-range"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  address       = cidrhost(var.private_services_cidr, 0)
  prefix_length = tonumber(split("/", var.private_services_cidr)[1])
  network       = google_compute_network.dev.self_link
}

resource "google_service_networking_connection" "private_sql" {
  network                 = google_compute_network.dev.self_link
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_sql_range.name]
}

# ponytail: 비밀번호는 random_password 로 생성해 SQL user 에 주입하고,
# GKE app(#5) 소비용 Secret Manager 저장은 secret_manager.tf 에 구현되어 있다.
resource "random_password" "db_app_password" {
  length  = 24
  special = true
}

resource "google_sql_database_instance" "dev" {
  name             = local.sql_instance_name
  database_version = var.db_database_version
  region           = var.region

  settings {
    tier              = var.db_tier
    availability_type = "ZONAL"

    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.dev.self_link
    }

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true
      start_time                     = "17:00"
    }

    # day: 1=Monday..7=Sunday. 7=Sunday 17:00 UTC = 월요일 02:00 KST.
    maintenance_window {
      update_track = "stable"
      day          = 7
      hour         = 17
    }

    deletion_protection_enabled = var.sql_deletion_protection
  }

  # dev: terraform destroy 허용. 운영 전환 시 true.
  deletion_protection = false
  depends_on          = [google_service_networking_connection.private_sql]
}

resource "google_sql_database" "dev" {
  name     = var.db_name
  instance = google_sql_database_instance.dev.name
}

resource "google_sql_user" "app" {
  name     = var.db_app_user
  instance = google_sql_database_instance.dev.name
  password = random_password.db_app_password.result
}
