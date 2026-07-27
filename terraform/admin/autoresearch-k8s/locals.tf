locals {
  app_gcp_service_account_email = var.app_gcp_service_account_email != "" ? var.app_gcp_service_account_email : "${var.resource_prefix}-app@${var.project_id}.iam.gserviceaccount.com"

  # #346 KSA annotation(WI 매핑)과 RoleBinding subject(GHA)가 같은 GSA다.
  # resource_prefix + project_id 파생이라 admin-apply.yml의 TF_VAR_* 배선이 필요 없다.
  feast_apply_gcp_service_account_email = var.feast_apply_gcp_service_account_email != "" ? var.feast_apply_gcp_service_account_email : "${var.resource_prefix}-feast-apply@${var.project_id}.iam.gserviceaccount.com"
}
