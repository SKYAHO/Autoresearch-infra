# #20 dev BigQuery analytics dataset
# GCS raw landing zone에서 정제/분석 가능한 데이터만 BigQuery table로 적재한다.
resource "google_bigquery_dataset" "analytics" {
  dataset_id                 = local.bigquery_dataset_id
  friendly_name              = "Autoresearch dev analytics"
  description                = "Structured dev analytics dataset for YouTube, user, action log, and persona data."
  location                   = var.bigquery_location
  delete_contents_on_destroy = var.bigquery_delete_contents_on_destroy

  labels = {
    data_class = "analytics"
    purpose    = "structured-analysis"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_bigquery_dataset_iam_member" "analytics_gke_app_data_editor" {
  dataset_id = google_bigquery_dataset.analytics.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.gke_app.email}"
}

resource "google_bigquery_dataset" "feast_offline_store" {
  dataset_id                 = local.feast_dataset_id
  friendly_name              = "Feast offline store"
  description                = "Dev BigQuery offline store dataset for Feast feature data."
  location                   = var.bigquery_location
  delete_contents_on_destroy = var.bigquery_delete_contents_on_destroy

  labels = {
    data_class = "feature-store"
    purpose    = "feast-offline-store"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_bigquery_dataset_iam_member" "feast_offline_store_gke_app_data_editor" {
  dataset_id = google_bigquery_dataset.feast_offline_store.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.gke_app.email}"
}

# #285 raw layer 전용 dataset
#
# GCS data lake 원천 적재 테이블(data_lake_*)을 Feast 피처 테이블과 같은
# dataset에 두면 dataset 단위 IAM·비용·수명주기 정책을 계층별로 다르게 걸 수
# 없다. raw는 이 dataset, feature는 feast_offline_store로 분리한다.
#
# ⚠️ 이 dataset과 하위 raw 테이블 2종은 운영자가 bq로 이미 생성·복사해 둔
# 실물이다. apply 전에 반드시 terraform import로 state에 편입해야 하며,
# 구 주소(feast_offline_store 하위)는 terraform state rm으로 분리한다.
# 절차는 docs/TERRAFORM_DEV.md "raw/feature layer 분리 state 재조정"을 따른다.
resource "google_bigquery_dataset" "data_lake_raw" {
  dataset_id                 = local.data_lake_raw_dataset_id
  friendly_name              = "Autoresearch dev data lake raw"
  description                = "Raw data lake layer: GCS dt-partition 원천 적재 테이블 전용 (feast_offline_store는 feature 전용으로 분리)"
  location                   = var.bigquery_location
  delete_contents_on_destroy = var.bigquery_delete_contents_on_destroy

  labels = {
    data_class = "raw"
    purpose    = "data-lake-raw"
  }

  lifecycle {
    prevent_destroy = true
  }
}

# dataset 이전으로 기존 접근 주체가 권한을 잃지 않도록, feast_offline_store가
# 가진 dataset 레벨 IAM 주체를 그대로 복제한다.
# - GKE app SA: 아래
# - Airflow SA / Airflow batch SA: airflow.tf
# - 팀원 계정: terraform/admin/gke-team-access (별도 state, 별도 apply 필요)
resource "google_bigquery_dataset_iam_member" "data_lake_raw_gke_app_data_editor" {
  dataset_id = google_bigquery_dataset.data_lake_raw.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.gke_app.email}"
}

resource "google_project_iam_member" "gke_app_bigquery_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.gke_app.email}"
}

# feast는 offline store(BigQuery) 결과를 BigQuery Storage Read API로 읽는다.
# jobUser/dataEditor에는 bigquery.readsessions.create가 없어 readSessionUser로 보강한다.
# (#204: #203 검증에서 materialize 시 readsessions.create 403으로 발견)
resource "google_project_iam_member" "gke_app_bigquery_read_session" {
  project = var.project_id
  role    = "roles/bigquery.readSessionUser"
  member  = "serviceAccount:${google_service_account.gke_app.email}"
}

# #199 data lake 테이블 dt 파티션 고정
# 스키마/데이터는 SKYAHO/Autoresearch scripts/load_raw_to_bigquery.py가 소유하고
# (autodetect + WRITE_TRUNCATE), Terraform은 존재와 dt 일 단위 파티셔닝만 보장한다.
#
# #285 dataset을 feast_offline_store → data_lake_raw로 이전. 스키마·파티션·
# deletion_protection은 데이터 유실 방지를 위해 이전 정의와 완전히 동일하다.
resource "google_bigquery_table" "data_lake_action_log" {
  dataset_id          = google_bigquery_dataset.data_lake_raw.dataset_id
  table_id            = "data_lake_action_log"
  description         = "GCS data_lake/action_log raw parquet 적재 테이블. dt 일 단위 파티션."
  deletion_protection = true

  time_partitioning {
    type  = "DAY"
    field = "dt"
  }

  # 파티션 필드는 생성 시점 스키마에 존재해야 한다. 이후 스키마는 적재 job이 관리한다.
  schema = jsonencode([
    {
      name        = "dt"
      type        = "DATE"
      mode        = "NULLABLE"
      description = "파티션 날짜 (GCS hive partition dt=* 복원 컬럼)"
    }
  ])

  labels = {
    data_class = "raw"
    purpose    = "data-lake-raw"
  }

  lifecycle {
    ignore_changes = [schema]
  }
}

resource "google_bigquery_table" "data_lake_youtube_trending_kr" {
  dataset_id          = google_bigquery_dataset.data_lake_raw.dataset_id
  table_id            = "data_lake_youtube_trending_kr"
  description         = "GCS data_lake/youtube_trending_kr raw parquet 적재 테이블. dt 일 단위 파티션."
  deletion_protection = true

  time_partitioning {
    type  = "DAY"
    field = "dt"
  }

  schema = jsonencode([
    {
      name        = "dt"
      type        = "DATE"
      mode        = "NULLABLE"
      description = "파티션 날짜 (GCS hive partition dt=* 복원 컬럼)"
    }
  ])

  labels = {
    data_class = "raw"
    purpose    = "data-lake-raw"
  }

  lifecycle {
    ignore_changes = [schema]
  }
}

# #300 가상 유저 raw 테이블 (정적 자산, 비 hive-partition)
# 스키마/데이터는 SKYAHO/Autoresearch scripts/load_raw_to_bigquery.py가 소유하고
# (parquet autodetect + WRITE_TRUNCATE, hive_partitioned=False), Terraform은 존재와
# 삭제 보호, 관리 라벨만 보장한다.
#
# parquet의 LIST<string> 필드는 BigQuery load 시 flat ARRAY<STRING>이 아니라
# wrapper record로 적재된다:
#   <field> RECORD NULLABLE { list: RECORD REPEATED { element: STRING NULLABLE } }
# feature_materialize.py의 _string_array()가 UNNEST(<col>.list)로 언래핑한다.
# Terraform은 스키마를 소유하지 않고 ignore_changes = [schema]로 둔다.
resource "google_bigquery_table" "asset_virtual_user_vu_1000" {
  dataset_id          = google_bigquery_dataset.data_lake_raw.dataset_id
  table_id            = "asset_virtual_user_vu_1000"
  description         = "가상 유저 페르소나 원본 parquet(vu_1000) raw 적재 테이블. 정적 자산이라 파티션 없음. 스키마는 SKYAHO/Autoresearch scripts/load_raw_to_bigquery.py가 소유(WRITE_TRUNCATE)한다."
  deletion_protection = true

  # 적재 스크립트가 전체 스키마를 소유한다. 존재 보장용 최소 seed 컬럼만 둔다.
  schema = jsonencode([
    { name = "user_id", type = "STRING", mode = "NULLABLE" },
  ])

  labels = {
    data_class = "raw"
    purpose    = "data-lake-raw"
    managed_by = "terraform"
    owner      = "infra"
  }

  lifecycle {
    ignore_changes = [schema]
  }
}

# #280 Feast 피처 테이블 4종
#
# data_lake_* 테이블과 달리 스키마를 Terraform이 소유한다. Feast FeatureView
# (SKYAHO/Autoresearch feature_repo/feature_definitions.py)가 컬럼명·타입·mode를
# 계약으로 선언하고 있어, 계약 위반을 terraform plan 단계에서 잡기 위함이다.
#
# 데이터는 SKYAHO/Autoresearch autoresearch.jobs.feature_store_build가 적재하며,
# createDisposition=CREATE_NEVER로 테이블을 새로 만들지 않는다.
#
# ⚠️ 적재는 WRITE_TRUNCATE가 아니라 TRUNCATE + INSERT INTO를 써야 한다.
# WRITE_TRUNCATE는 대상 테이블 스키마까지 결과 스키마로 교체하며(CREATE_NEVER는
# 테이블 생성만 막는다), 2026-07-21 실측에서 REQUIRED가 NULLABLE로 파괴되는 것을
# 확인했다. DML(TRUNCATE + INSERT)은 스키마를 바꾸지 않아 이 정의가 보호되고,
# REQUIRED 컬럼에 NULL이 들어오면 BigQuery가 거부한다. 상세는 #280 참조.

resource "google_bigquery_table" "user_static_feature" {
  dataset_id          = google_bigquery_dataset.feast_offline_store.dataset_id
  table_id            = "user_static_feature"
  description         = "페르소나 기반 유저 정적 피처. Feast UserStaticView 소스."
  deletion_protection = true

  # event_timestamp가 1970-01-01 고정값(정적 피처가 모든 action log보다 먼저
  # 유효하다는 규약)이라 파티셔닝이 무의미하다.

  schema = jsonencode([
    { name = "user_id", type = "STRING", mode = "REQUIRED" },
    { name = "event_timestamp", type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "age_group", type = "STRING", mode = "NULLABLE" },
    { name = "occupation", type = "STRING", mode = "NULLABLE" },
    { name = "preferred_category", type = "STRING", mode = "REPEATED" },
    { name = "preferred_topics", type = "STRING", mode = "REPEATED" },
    { name = "watch_time_band", type = "STRING", mode = "NULLABLE" },
  ])

  labels = {
    data_class = "feature-store"
    purpose    = "feast-feature-table"
  }
}

resource "google_bigquery_table" "user_dynamic_feature" {
  dataset_id          = google_bigquery_dataset.feast_offline_store.dataset_id
  table_id            = "user_dynamic_feature"
  description         = "action log 기반 유저 동적 피처(일 단위 snapshot). Feast UserDynamicView 소스."
  deletion_protection = true

  # 일 단위 snapshot이 누적되고 feast materialize가 timestamp 범위로 스캔하므로
  # DAY 파티션이 스캔 비용에 직접 기여한다.
  time_partitioning {
    type  = "DAY"
    field = "event_timestamp"
  }

  schema = jsonencode([
    { name = "user_id", type = "STRING", mode = "REQUIRED" },
    { name = "event_timestamp", type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "recent_click_count_7d", type = "INTEGER", mode = "NULLABLE" },
    { name = "recent_view_count_7d", type = "INTEGER", mode = "NULLABLE" },
    { name = "recent_watch_time_7d", type = "INTEGER", mode = "NULLABLE" },
    { name = "recent_like_count_7d", type = "INTEGER", mode = "NULLABLE" },
    { name = "historical_category_affinity", type = "STRING", mode = "NULLABLE" },
    { name = "total_event_count_7d", type = "INTEGER", mode = "NULLABLE" },
  ])

  labels = {
    data_class = "feature-store"
    purpose    = "feast-feature-table"
  }
}

# #295 임베딩 중간 산출물 테이블 2종
#
# user_category_similarity(Feast feature table)를 만드는 원본이지만 그 자체는
# Feast FeatureView 소스가 아니라 analytics dataset의 중간 산출물이라, feature
# 테이블과 달리 feast_offline_store가 아니라 analytics dataset에 둔다.
#
# 스키마는 Terraform이 아니라 적재 스크립트(SKYAHO/Autoresearch
# scripts/build_static_features.py)가 소유한다. 스크립트가 매번 WRITE_TRUNCATE로
# 테이블 전체를 재생성하므로, Terraform이 schema를 소유하면 매 적재마다 충돌한다.
# 따라서 feature 테이블의 full-schema 패턴이 아니라 raw 테이블(data_lake_*)의
# 존재만 관리(ignore_changes = [schema]) 패턴을 따른다. 재생성 가능한 중간
# 산출물이므로 deletion_protection도 끈다.
resource "google_bigquery_table" "user_topic_embedding" {
  dataset_id          = google_bigquery_dataset.analytics.dataset_id
  table_id            = "user_topic_embedding"
  description         = "persona 관심 키워드의 Vertex AI 임베딩(행별 topic). Feast feature table이 아니라 analytics dataset의 임베딩 중간 산출물이며, 스키마는 SKYAHO/Autoresearch scripts/build_static_features.py가 소유(WRITE_TRUNCATE)한다."
  deletion_protection = false

  # 적재 스크립트가 전체 스키마를 소유한다. 존재 보장용 최소 seed 컬럼만 둔다.
  schema = jsonencode([
    { name = "user_id", type = "STRING", mode = "REQUIRED" },
  ])

  labels = {
    data_class = "analytics"
    purpose    = "embedding-intermediate"
  }

  lifecycle {
    ignore_changes = [schema]
  }
}

resource "google_bigquery_table" "category_embedding" {
  dataset_id          = google_bigquery_dataset.analytics.dataset_id
  table_id            = "category_embedding"
  description         = "15개 YouTube 카테고리 설명문의 Vertex AI 임베딩 참조 테이블. Feast feature table이 아니라 analytics dataset의 임베딩 중간 산출물이며, 스키마는 SKYAHO/Autoresearch scripts/build_static_features.py가 소유(WRITE_TRUNCATE)한다."
  deletion_protection = false

  schema = jsonencode([
    { name = "category_id", type = "STRING", mode = "REQUIRED" },
  ])

  labels = {
    data_class = "analytics"
    purpose    = "embedding-intermediate"
  }

  lifecycle {
    ignore_changes = [schema]
  }
}

resource "google_bigquery_table" "video_feature" {
  dataset_id          = google_bigquery_dataset.feast_offline_store.dataset_id
  table_id            = "video_feature"
  description         = "YouTube 영상·채널 피처. Feast VideoFeatureView 소스."
  deletion_protection = true

  time_partitioning {
    type  = "DAY"
    field = "event_timestamp"
  }

  schema = jsonencode([
    { name = "video_id", type = "STRING", mode = "REQUIRED" },
    { name = "event_timestamp", type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "category_id", type = "STRING", mode = "NULLABLE" },
    { name = "duration_sec", type = "INTEGER", mode = "NULLABLE" },
    { name = "view_count", type = "INTEGER", mode = "NULLABLE" },
    { name = "like_ratio", type = "FLOAT", mode = "NULLABLE" },
    { name = "comment_ratio", type = "FLOAT", mode = "NULLABLE" },
    { name = "days_since_upload", type = "INTEGER", mode = "NULLABLE" },
    { name = "channel_subscriber_count", type = "INTEGER", mode = "NULLABLE" },
    { name = "channel_view_count", type = "INTEGER", mode = "NULLABLE" },
    { name = "channel_video_count", type = "INTEGER", mode = "NULLABLE" },
  ])

  labels = {
    data_class = "feature-store"
    purpose    = "feast-feature-table"
  }
}

resource "google_bigquery_table" "user_category_similarity" {
  dataset_id          = google_bigquery_dataset.feast_offline_store.dataset_id
  table_id            = "user_category_similarity"
  description         = "유저 관심 키워드 ↔ 카테고리 설명문 임베딩 간 코사인 유사도. Feast UserCategorySimilarityView 소스."
  deletion_protection = true

  # user_static_feature와 동일하게 event_timestamp가 1970-01-01 고정값이라
  # 파티셔닝하지 않는다.

  schema = jsonencode([
    { name = "user_id", type = "STRING", mode = "REQUIRED" },
    { name = "category_id", type = "STRING", mode = "REQUIRED" },
    { name = "event_timestamp", type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "topic_similarity", type = "FLOAT", mode = "NULLABLE" },
    { name = "topic_similarity_top_topic", type = "STRING", mode = "NULLABLE" },
    { name = "embedding_model", type = "STRING", mode = "NULLABLE" },
    { name = "embedding_dim", type = "INTEGER", mode = "NULLABLE" },
    { name = "user_topic_embedding_version", type = "STRING", mode = "NULLABLE" },
    { name = "category_embedding_version", type = "STRING", mode = "NULLABLE" },
    { name = "similarity_method", type = "STRING", mode = "NULLABLE" },
    { name = "similarity_pooling", type = "STRING", mode = "NULLABLE" },
  ])

  labels = {
    data_class = "feature-store"
    purpose    = "feast-feature-table"
  }
}
