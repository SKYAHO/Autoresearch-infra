locals {
  actions_runner_controller_gcp_service_account_email = var.actions_runner_controller_gcp_service_account_email != "" ? var.actions_runner_controller_gcp_service_account_email : "${var.resource_prefix}-runner@${var.project_id}.iam.gserviceaccount.com"
}
