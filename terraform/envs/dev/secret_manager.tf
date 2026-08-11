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

# Agent Orchestration API와 #539 launcher, #616 로그 수집기, #630 PR 생성기만 전용
# DB 비밀번호를 읽는다. 넷은 같은 database의 같은 애플리케이션 user를 쓰므로 secret도
# 같은 하나다. Codex Runner는 이 secret에 접근하지 않는다. Kubernetes Secret, Pod
# manifest, 컨테이너 이미지에는 DB URL·비밀번호를 두지 않는다.
resource "google_secret_manager_secret" "agent_orchestration_db_password" {
  secret_id = local.agent_orchestration_db_password_secret_id

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "agent_orchestration_db_password" {
  secret      = google_secret_manager_secret.agent_orchestration_db_password.id
  secret_data = random_password.agent_orchestration_db.result
}

resource "google_secret_manager_secret_iam_member" "agent_orchestration_api_db_password" {
  secret_id = google_secret_manager_secret.agent_orchestration_db_password.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.agent_orchestration_api.email}"
}

resource "google_secret_manager_secret_iam_member" "agent_orchestration_launcher_db_password" {
  secret_id = google_secret_manager_secret.agent_orchestration_db_password.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.agent_orchestration_launcher.email}"
}

resource "google_secret_manager_secret_iam_member" "agent_orchestration_log_collector_db_password" {
  secret_id = google_secret_manager_secret.agent_orchestration_db_password.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.agent_orchestration_log_collector.email}"
}

resource "google_secret_manager_secret_iam_member" "agent_orchestration_pull_request_db_password" {
  secret_id = google_secret_manager_secret.agent_orchestration_db_password.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.agent_orchestration_pull_request.email}"
}

# Codex OAuth 초기 인증 파일의 컨테이너 밖 정본. payload(version)는 Terraform이
# 관리하지 않으며 신뢰된 운영자가 Task 6 runbook 절차로만 추가한다. 삭제하면
# 갱신된 OAuth 상태를 복구할 수 없으므로 명시적인 lifecycle 보호를 둔다.
resource "google_secret_manager_secret" "agent_orchestration_codex_auth_bootstrap" {
  secret_id = local.agent_orchestration_codex_auth_bootstrap_secret_id

  replication {
    auto {}
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_secret_manager_secret_iam_member" "agent_orchestration_runner_codex_auth" {
  secret_id = google_secret_manager_secret.agent_orchestration_codex_auth_bootstrap.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.agent_orchestration_runner.email}"
}

# #494 ArgoCD Google OIDC client 자격 정본. 라이브에 이미 존재하던 컨테이너를
# import로 state에 입양(값 변경 없음). 이름은 resource_prefix 접두사 규칙의
# 의도적 예외 — 기존 라이브 이름을 유지해야 README의 `gcloud secrets versions
# access --secret argocd-google-oidc-client-id` 절차와 argo-cd.values.yaml.tftpl의
# `$argocd-google-oidc:clientId` 참조 경로가 그대로 유효하다(설계 근거:
# docs/superpowers/specs/2026-08-02-argocd-oidc-secret-iac-design.md). 값(version)은
# Terraform이 관리하지 않으며 운영자가 gcloud로 직접 채운다(accessor 없음, UI
# OAuth 4종과 동일).
resource "google_secret_manager_secret" "argocd_google_oidc_client" {
  for_each = toset([
    "argocd-google-oidc-client-id",
    "argocd-google-oidc-client-secret",
  ])
  secret_id = each.key

  replication {
    auto {}
  }

  # payload는 destroy 시 복구 불가 — UI OAuth 4종·mlflow #420과 같은 보호.
  lifecycle {
    prevent_destroy = true
  }
}

# #439 Grafana·Kibana UI OAuth client 자격 정본. mlflow(#420)·argocd(#494)와 대칭 —
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
