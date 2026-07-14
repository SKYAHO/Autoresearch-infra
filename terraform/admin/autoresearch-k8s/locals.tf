locals {
  app_gcp_service_account_email = var.app_gcp_service_account_email != "" ? var.app_gcp_service_account_email : "${var.resource_prefix}-app@${var.project_id}.iam.gserviceaccount.com"
}
