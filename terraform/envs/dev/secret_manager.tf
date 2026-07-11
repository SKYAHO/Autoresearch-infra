# #5 DB app 비밀번호를 Secret Manager에 저장 (← #4에서 GKE app 소비 시점으로 미룬 것).
# random_password.db_app_password 는 cloud_sql.tf(#4)에 이미 존재.
# ponytail: random_password.result 는 Terraform state 에 평문 저장됨(근본 한계).
# state 노출 회피는 GCS 원격 backend + 접근제어로 후속 이슈에서 처리. dev 범위에서는 accept.
resource "google_secret_manager_secret" "db_app_password" {
  secret_id = local.db_password_secret_id

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "db_app_password" {
  secret      = google_secret_manager_secret.db_app_password.id
  secret_data = random_password.db_app_password.result
}

# 최소 권한: app GCP SA 에 이 secret 에만 접근 권한 부여(프로젝트 전체 secret 아님).
resource "google_secret_manager_secret_iam_member" "gke_app_db_password" {
  secret_id = google_secret_manager_secret.db_app_password.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.gke_app.email}"
}

# #129 Redis AUTH token과 TLS server CA를 앱에 전달한다. 두 값 모두
# Terraform state에 저장되므로 backend IAM을 최소화하고 output으로 노출하지 않는다.
resource "google_secret_manager_secret" "redis_auth" {
  secret_id = local.redis_auth_secret_id

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "redis_auth" {
  secret      = google_secret_manager_secret.redis_auth.id
  secret_data = google_redis_instance.online_store.auth_string
}

resource "google_secret_manager_secret_iam_member" "gke_app_redis_auth" {
  secret_id = google_secret_manager_secret.redis_auth.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.gke_app.email}"
}

resource "google_secret_manager_secret" "redis_server_ca" {
  secret_id = local.redis_server_ca_secret_id

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "redis_server_ca" {
  secret      = google_secret_manager_secret.redis_server_ca.id
  secret_data = join("\n", google_redis_instance.online_store.server_ca_certs[*].cert)
}

resource "google_secret_manager_secret_iam_member" "gke_app_redis_server_ca" {
  secret_id = google_secret_manager_secret.redis_server_ca.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.gke_app.email}"
}
