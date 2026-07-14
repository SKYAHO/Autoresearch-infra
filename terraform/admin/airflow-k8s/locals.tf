locals {
  airflow_gcp_service_account_email      = var.airflow_gcp_service_account_email != "" ? var.airflow_gcp_service_account_email : "${var.resource_prefix}-airflow@${var.project_id}.iam.gserviceaccount.com"
  airflow_deployer_service_account_email = var.airflow_deployer_service_account_email != "" ? var.airflow_deployer_service_account_email : "${var.resource_prefix}-airflow-cd@${var.project_id}.iam.gserviceaccount.com"
}
