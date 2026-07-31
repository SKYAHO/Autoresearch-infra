# #4 dev Cloud SQL (PostgreSQL, private IP)
# password: random 생성 → SQL user 주입. Secret Manager 저장은 secret_manager.tf(#5)에 구현.
# private IP: VPC 전용 대역 할당 후 servicenetworking peering.
# Redis Cluster(#129)는 별도 PSC subnet을 사용하므로 이 PSA 대역은 Cloud SQL 전용이다.

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
  # #438: URI-unsafe 문자 배제 — airflow metadata conn 등이 비번을 URI에 삽입.
  # 이 문자셋 변경은 다음 apply에서 비밀번호를 재생성(rotate)하므로,
  # apply 직후 소비 Secret 재주입·재기동이 한 절차다(MIGRATION_RUNBOOK 참조).
  override_special = "-_.~"
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

# --- #93 MLflow backend: 기존 인스턴스에 전용 DB/user (Airflow/앱과 논리 분리) ---
# 8회차 "DB 외부화" 결정 반영. 신규 인스턴스 없이 schema/DB 분리로 비용 회피.
resource "random_password" "mlflow_db_password" {
  length  = 24
  special = true
  # #438: mlflow가 backend-store URI에 비번을 원문 삽입 — URL-인코딩 우회(#404)
  # 없이 안전하도록 URI-unsafe 문자를 배제한다. 변경은 rotate를 유발(위 주석 참조).
  override_special = "-_.~"
}

resource "google_sql_database" "mlflow" {
  name     = var.mlflow_db_name
  instance = google_sql_database_instance.dev.name
}

resource "google_sql_user" "mlflow" {
  name     = var.mlflow_db_user
  instance = google_sql_database_instance.dev.name
  password = random_password.mlflow_db_password.result
}

# Agent Orchestration은 기존 인스턴스를 공유하되, 다른 앱 DB와 사용자 자격 증명을
# 공유하지 않는다. 신규 인스턴스를 만들지 않아 dev 비용을 늘리지 않는다.
resource "random_password" "agent_orchestration_db" {
  length  = 24
  special = true
  # DB URL에 percent-encoding을 적용하더라도 운영 중 수동 접속 시 혼선을 줄이기 위해
  # URI-unsafe 문자는 배제한다. 이 변경은 apply 시 password rotate를 유발한다.
  override_special = "-_.~"
}

resource "google_sql_database" "agent_orchestration" {
  name     = var.agent_orchestration_db_name
  instance = google_sql_database_instance.dev.name
}

resource "google_sql_user" "agent_orchestration" {
  name           = var.agent_orchestration_db_user
  instance       = google_sql_database_instance.dev.name
  password       = random_password.agent_orchestration_db.result
  database_roles = [var.agent_orchestration_runtime_database_role]

  # PostgreSQL role membership이 있는 Cloud SQL user는 API delete가 실패할 수 있다.
  # 서비스 폐기는 runbook의 SQL 정리 절차를 먼저 거친 뒤 Terraform state/config을
  # 정리한다. 이 리소스를 config에서 제거할 때 provider가 membership을 임의로
  # 해제하거나 user delete를 시도하지 않도록 명시적으로 abandon한다.
  deletion_policy = "ABANDON"
}
