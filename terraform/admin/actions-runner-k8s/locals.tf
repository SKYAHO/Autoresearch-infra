locals {
  actions_runner_controller_gcp_service_account_email = var.actions_runner_controller_gcp_service_account_email != "" ? var.actions_runner_controller_gcp_service_account_email : "${var.resource_prefix}-runner@${var.project_id}.iam.gserviceaccount.com"

  # 이 namespace에는 ephemeral runner Pod 외에 ARC 컨트롤러 매니저 1개 +
  # 스케일셋마다 리스너(AutoscalingListener) 1개가 항상 함께 뜬다(#533 리뷰,
  # #541로 스케일셋이 PoC/feast-dev/feast-prod 3개가 되며 리스너도 3개로
  # 늘어난다) — quota를 max_pods 합으로만 잡으면 컨트롤러/리스너가 그 몫을
  # 먹어 실제 동시 러너 수가 maxRunners 합보다 줄어든다. 리스너 Pod는 각
  # `deploy/actions-runner-scale-set*` ArgoCD Application의
  # `destination.namespace`(= `var.actions_runner_namespace`, 전부 이
  # namespace)에 뜬다 — 그래서 이 root의 ResourceQuota에 계상 대상이다
  # (#541 리뷰 이해도 확인).
  #
  # quota(pods) 초과 시: 추가 Pod 생성 요청이 API server admission에서
  # 거부되고, ARC 컨트롤러는 재시도 백오프만 반복한다. GitHub Actions
  # 쪽에서는 "Waiting for a runner to pick up this job..."으로 무한 대기
  # 상태만 보이고 에러가 표시되지 않는다 — 러너가 아예 없을 때와 증상이
  # 같아 구분이 안 된다. 이 root는 스케일셋 간 우선순위를 걸지 않는다
  # (PriorityClass·전용 quota 분리 없음) — PoC와 feast-apply-prod가 동시에
  # quota를 다툴 때 어느 쪽이 먼저 admission을 통과할지는 각 EphemeralRunnerSet
  # 컨트롤러의 reconcile 타이밍에 달려 있어 예측 가능한 우선순위가 없다.
  # prod가 실제로 밀리는 사례가 관측되면 feast-apply-prod 전용 ResourceQuota
  # 분리를 검토한다(현재는 범위 밖).
  # PoC 스케일셋 1개(맵으로 관리하지 않음) + feast_apply_runner_identities
  # 맵 원소 수. 스케일셋을 추가할 때 이 숫자를 별도로 고칠 필요가 없도록
  # 리터럴 대신 맵 길이에서 파생한다(#541 리뷰).
  actions_runner_scale_set_count    = 1 + length(local.feast_apply_runner_identities)
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
