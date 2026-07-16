locals {
  mlflow_gcp_service_account_email = var.mlflow_gcp_service_account_email != "" ? var.mlflow_gcp_service_account_email : "${var.resource_prefix}-mlflow@${var.project_id}.iam.gserviceaccount.com"
}
