locals {
  airflow_gcp_service_account_email = var.airflow_gcp_service_account_email != "" ? var.airflow_gcp_service_account_email : "${var.resource_prefix}-airflow@${var.project_id}.iam.gserviceaccount.com"
}
