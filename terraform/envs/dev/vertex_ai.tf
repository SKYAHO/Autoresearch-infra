# #280 BigQuery ↔ Vertex AI connection
#
# user_category_similarity.topic_similarity는 한국어 페르소나 키워드와 카테고리
# 설명문 간 코사인 유사도다. 다국어 임베딩이 필요해 BigQuery ML
# ML.GENERATE_EMBEDDING으로 Vertex AI를 호출하며, 그 경로가 이 connection이다.
#
# connection의 location은 feast_offline_store 데이터셋과 반드시 같아야 한다.
# BigQuery ML remote model은 connection·데이터셋이 동일 리전일 때만 동작한다.
#
# remote model(CREATE MODEL ... REMOTE WITH CONNECTION)은 배치 job이 멱등하게
# 생성한다. Terraform 범위는 connection과 IAM까지다.
resource "google_bigquery_connection" "vertex_ai" {
  connection_id = "${local.resource_prefix}-vertex-ai"
  location      = var.bigquery_location
  friendly_name = "Vertex AI (BigQuery ML remote model)"
  description   = "BigQuery ML ML.GENERATE_EMBEDDING이 Vertex AI를 호출하는 CLOUD_RESOURCE connection."

  cloud_resource {}
}

# connection이 자동 생성하는 service agent에 Vertex AI 호출 권한을 부여한다.
# 이 SA는 connection에 종속되며 다른 용도로 쓰이지 않는다.
resource "google_project_iam_member" "vertex_ai_connection_user" {
  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_bigquery_connection.vertex_ai.cloud_resource[0].service_account_id}"
}

# Airflow 워크로드 GSA. lake_to_bigquery_incremental과 동일 계정이 피처 빌드
# BigQuery job을 실행하며, ML.GENERATE_EMBEDDING 호출과 remote model 생성에
# aiplatform.user가 필요하다.
# BigQuery dataEditor·jobUser·readSessionUser는 airflow.tf에서 이미 부여한다.
resource "google_project_iam_member" "airflow_aiplatform_user" {
  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_service_account.airflow.email}"
}

resource "google_project_iam_member" "airflow_batch_aiplatform_user" {
  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_service_account.airflow_batch.email}"
}
