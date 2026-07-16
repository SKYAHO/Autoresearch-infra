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

# #129 Redis Cluster TLS server CA bundle을 앱에 전달한다. IAM access token은
# Workload Identity로 런타임 발급하며 Secret Manager나 Terraform state에 저장하지 않는다.
resource "google_secret_manager_secret" "redis_server_ca" {
  secret_id = local.redis_server_ca_secret_id

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "redis_server_ca" {
  secret = google_secret_manager_secret.redis_server_ca.id
  secret_data = join("\n", flatten([
    for managed_ca in google_redis_cluster.online_store.managed_server_ca : [
      for ca_cert in managed_ca.ca_certs : ca_cert.certificates
    ]
  ]))
}

resource "google_secret_manager_secret_iam_member" "gke_app_redis_server_ca" {
  secret_id = google_secret_manager_secret.redis_server_ca.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.gke_app.email}"
}

# #93 MLflow DB 비밀번호를 Secret Manager에 저장. random_password는 cloud_sql.tf.
# state 평문 저장 한계는 db_app_password와 동일(GCS backend 접근제어로 완화, dev accept).
resource "google_secret_manager_secret" "mlflow_db_password" {
  secret_id = local.mlflow_db_password_secret_id

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "mlflow_db_password" {
  secret      = google_secret_manager_secret.mlflow_db_password.id
  secret_data = random_password.mlflow_db_password.result
}

# 최소 권한: MLflow GSA에 이 secret에만 접근 부여(프로젝트 전체 아님).
resource "google_secret_manager_secret_iam_member" "mlflow_db_password" {
  secret_id = google_secret_manager_secret.mlflow_db_password.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.mlflow.email}"
}
