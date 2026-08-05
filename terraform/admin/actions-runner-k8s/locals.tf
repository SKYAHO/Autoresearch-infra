locals {
  actions_runner_controller_gcp_service_account_email = var.actions_runner_controller_gcp_service_account_email != "" ? var.actions_runner_controller_gcp_service_account_email : "${var.resource_prefix}-runner@${var.project_id}.iam.gserviceaccount.com"

  # 이 namespace에는 ephemeral runner Pod 외에 ARC 컨트롤러 매니저 1개 +
  # 스케일셋마다 리스너(AutoscalingListener) 1개가 항상 함께 뜬다(#533 리뷰,
  # #541로 스케일셋이 PoC/feast-dev/feast-prod 3개가 되며 리스너도 3개로
  # 늘어난다) — quota를 max_pods 합으로만 잡으면 컨트롤러/리스너가 그 몫을
  # 먹어 실제 동시 러너 수가 maxRunners 합보다 줄어든다.
  actions_runner_scale_set_count    = 3
  actions_runner_control_plane_pods = 1 + local.actions_runner_scale_set_count
  actions_runner_quota_pods         = var.actions_runner_max_pods + var.feast_apply_dev_max_pods + var.feast_apply_prod_max_pods + local.actions_runner_control_plane_pods

  # #541 5단계: terraform/admin/autoresearch-k8s/locals.tf의
  # feast_apply_default_identities와 같은 local part 파생 규칙(-feast-dev/
  # -feast-prod). 새 GSA를 만들지 않고 #424 GSA를 그대로 재사용한다.
  feast_apply_dev_gcp_service_account_email  = var.feast_apply_dev_gcp_service_account_email != "" ? var.feast_apply_dev_gcp_service_account_email : "${var.resource_prefix}-feast-dev@${var.project_id}.iam.gserviceaccount.com"
  feast_apply_prod_gcp_service_account_email = var.feast_apply_prod_gcp_service_account_email != "" ? var.feast_apply_prod_gcp_service_account_email : "${var.resource_prefix}-feast-prod@${var.project_id}.iam.gserviceaccount.com"

  # KSA 이름·스케일셋 라벨 값을 한 튜플로 묶는다 — NetworkPolicy egress의
  # pod_selector가 참조하는 scale_set_name은 deploy/actions-runner-scale-set-
  # feast-{dev,prod}/values.yaml의 runnerScaleSetName과 반드시 같아야 한다.
  feast_apply_runner_identities = {
    dev = {
      ksa_name                  = "feast-apply-dev-runner"
      scale_set_name            = "feast-apply-dev"
      gcp_service_account_email = local.feast_apply_dev_gcp_service_account_email
    }
    prod = {
      ksa_name                  = "feast-apply-prod-runner"
      scale_set_name            = "feast-apply-prod"
      gcp_service_account_email = local.feast_apply_prod_gcp_service_account_email
    }
  }
}
