locals {
  app_gcp_service_account_email = var.app_gcp_service_account_email != "" ? var.app_gcp_service_account_email : "${var.resource_prefix}-app@${var.project_id}.iam.gserviceaccount.com"

  # #424 Task 2의 Workload Identity subject와 정확히 같은 namespace/KSA 기본값을
  # 사용한다. annotation과 RoleBinding은 반드시 같은 환경의 GSA만 참조한다.
  # GSA local part는 dev root의 feast_apply_{dev,prod}_sa_name과 같아야 한다.
  # 30자 account_id 제한 때문에 namespace(`feast-apply-dev`)와 달리 GSA는
  # `-feast-dev`/`-feast-prod`로 줄어 있으므로 두 이름을 혼동하면 안 된다.
  feast_apply_default_identities = {
    dev = {
      namespace                 = "feast-apply-dev"
      service_account           = "feast-apply"
      gcp_service_account_email = "${var.resource_prefix}-feast-dev@${var.project_id}.iam.gserviceaccount.com"
    }
    prod = {
      namespace                 = "feast-apply-prod"
      service_account           = "feast-apply"
      gcp_service_account_email = "${var.resource_prefix}-feast-prod@${var.project_id}.iam.gserviceaccount.com"
    }
  }

  feast_apply_identities = var.feast_apply_identities == null ? local.feast_apply_default_identities : var.feast_apply_identities
}
