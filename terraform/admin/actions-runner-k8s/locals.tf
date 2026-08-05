locals {
  actions_runner_controller_gcp_service_account_email = var.actions_runner_controller_gcp_service_account_email != "" ? var.actions_runner_controller_gcp_service_account_email : "${var.resource_prefix}-runner@${var.project_id}.iam.gserviceaccount.com"

  # 이 namespace에는 ephemeral runner Pod(최대 actions_runner_max_pods개) 외에
  # ARC 컨트롤러 매니저 1개 + 스케일셋 리스너(AutoscalingListener) 1개가 항상
  # 함께 뜬다(#533 리뷰) — quota를 max_pods로만 잡으면 컨트롤러/리스너가 그
  # 몫을 먹어 실제 동시 러너 수가 maxRunners보다 줄어든다.
  actions_runner_control_plane_pods = 2
  actions_runner_quota_pods         = var.actions_runner_max_pods + local.actions_runner_control_plane_pods
}
