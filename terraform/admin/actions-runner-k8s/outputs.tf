output "actions_runner_platform_contract" {
  description = "셀프 호스티드 러너(ARC) namespace/KSA/NetworkPolicy 좌표(#533). Secret 값은 포함하지 않는다."
  value = {
    namespace                  = kubernetes_namespace_v1.actions_runner.metadata[0].name
    controller_service_account = kubernetes_service_account_v1.actions_runner_controller.metadata[0].name
    runner_service_account     = kubernetes_service_account_v1.actions_runner_runner.metadata[0].name
    ingress_network_policy     = kubernetes_network_policy_v1.actions_runner_ingress.metadata[0].name
    egress_network_policy      = kubernetes_network_policy_v1.actions_runner_egress.metadata[0].name
    pods_quota                 = local.actions_runner_quota_pods
  }
}
