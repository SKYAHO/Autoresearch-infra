# #22 dev BigQuery 쿼리 비용 가드
# app SA에 project-level roles/bigquery.jobUser가 있어(#20) 잘못된 쿼리가
# 큰 테이블을 스캔하면 on-demand 비용이 튈 수 있다. Service Usage 커스텀
# 쿼터로 일일 쿼리 스캔량에 하드 상한을 둔다. 초과 시 쿼리는 실패한다.
#
# - 단위: MiB (콘솔 표시는 TiB). 예: 204800 MiB = 200 GiB.
# - job-level 가드(maximum_bytes_billed)는 Terraform으로 강제할 수 없어
#   앱/배치 설정으로 관리한다. 기준값은 docs/TERRAFORM_DEV.md 참조.
# - 주의: 같은 쿼터를 콘솔에서 이미 수동 설정했다면 apply 시 409가
#   발생하므로 terraform import로 기존 override를 가져와야 한다.

resource "google_service_usage_consumer_quota_override" "bigquery_query_usage_per_day" {
  provider = google-beta

  project        = var.project_id
  service        = "bigquery.googleapis.com"
  metric         = urlencode("bigquery.googleapis.com/quota/query/usage")
  limit          = urlencode("/d/project")
  override_value = var.bq_query_usage_per_day_mib
  force          = true
}

resource "google_service_usage_consumer_quota_override" "bigquery_query_usage_per_user_per_day" {
  provider = google-beta

  project        = var.project_id
  service        = "bigquery.googleapis.com"
  metric         = urlencode("bigquery.googleapis.com/quota/query/usage")
  limit          = urlencode("/d/project/user")
  override_value = var.bq_query_usage_per_user_per_day_mib
  force          = true
}
