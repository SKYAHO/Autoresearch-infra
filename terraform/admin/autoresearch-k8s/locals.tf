locals {
  app_gcp_service_account_email = var.app_gcp_service_account_email != "" ? var.app_gcp_service_account_email : "${var.resource_prefix}-app@${var.project_id}.iam.gserviceaccount.com"

  # #424 Task 2의 Workload Identity subject와 정확히 같은 namespace/KSA 기본값을
  # 사용한다. annotation과 RoleBinding은 반드시 같은 환경의 GSA만 참조한다.
  feast_apply_default_identities = {
    dev = {
      namespace                 = "feast-apply-dev"
      service_account           = "feast-apply"
      gcp_service_account_email = "${var.resource_prefix}-feast-apply-dev@${var.project_id}.iam.gserviceaccount.com"
    }
    prod = {
      namespace                 = "feast-apply-prod"
      service_account           = "feast-apply"
      gcp_service_account_email = "${var.resource_prefix}-feast-apply-prod@${var.project_id}.iam.gserviceaccount.com"
    }
  }

  feast_apply_identities = var.feast_apply_identities == null ? local.feast_apply_default_identities : var.feast_apply_identities
}
