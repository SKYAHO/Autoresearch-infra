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

# #263 Feast materialize DAG는 TLS(SERVER_AUTHENTICATION) 검증용 CA가 필요하다.
# 이 secret 하나에만 accessor를 부여하고 프로젝트 수준 Secret Manager 권한은 주지 않는다.
resource "google_secret_manager_secret_iam_member" "airflow_batch_redis_server_ca" {
  secret_id = google_secret_manager_secret.redis_server_ca.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.airflow_batch.email}"
}

# #346 GKE Job으로 실행되는 feast apply도 online store 삭제 스캔 시 Redis에
# TLS(SERVER_AUTHENTICATION)로 접속하므로 같은 CA가 필요하다. gke_app/airflow_batch와
# 동일하게 이 secret 하나에만 accessor를 부여한다.
resource "google_secret_manager_secret_iam_member" "feast_apply_prod_redis_server_ca" {
  secret_id = google_secret_manager_secret.redis_server_ca.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.feast_apply_prod.email}"
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

# #439 Grafana·Kibana UI OAuth client 자격 정본. mlflow(#420)·argocd와 대칭 —
# 재발급은 id/secret이 한 쌍으로 바뀌므로 둘 다 SM에 정본을 둬야 runbook
# 하드코딩/클러스터 값 갈림("재발급 ≠ 반영", #404 실측)이 재발하지 않는다.
# 값(version)은 operator가 넣고, 주입도 운영자 자격으로 읽는다(accessor 없음).
resource "google_secret_manager_secret" "ui_oauth_clients" {
  for_each = toset([
    "grafana-oauth-client-id",
    "grafana-oauth-client-secret",
    "kibana-oauth-client-id",
    "kibana-oauth-client-secret",
  ])
  secret_id = "${local.resource_prefix}-${each.key}"

  replication {
    auto {}
  }

  # payload는 destroy 시 복구 불가 — airflow #54·mlflow #420과 같은 보호.
  # 운영 주의(#445 리뷰): for_each 항목 제거/키 변경은 해당 인스턴스 destroy를
  # 유발하므로 plan 단계에서 이 lifecycle이 오류로 막는다 — 의도된 제거라면
  # ① payload 백업 ② 이 블록을 임시 해제(또는 state rm) ③ 항목 제거 순.
  # dev root 전체 destroy도 같은 이유로 여기서 멈춘다(기존 SM secret들과 동일).
  lifecycle {
    prevent_destroy = true
  }
}
