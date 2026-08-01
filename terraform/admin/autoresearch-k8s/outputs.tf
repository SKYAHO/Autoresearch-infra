output "app_namespace" {
  description = "Autoresearch application Kubernetes namespace."
  value       = kubernetes_namespace_v1.autoresearch.metadata[0].name
}

output "app_service_account" {
  description = "Autoresearch Workload Identity Kubernetes service account."
  value       = kubernetes_service_account_v1.app.metadata[0].name
}

output "app_egress_network_policy" {
  description = "NetworkPolicy that allows minimum application egress including Redis Cluster PSC topology traffic."
  value       = kubernetes_network_policy_v1.app_egress.metadata[0].name
}

output "agent_orchestration_service_accounts" {
  description = "Agent Orchestration API와 Codex Runner의 분리된 Workload Identity Kubernetes service account."
  value = {
    api = {
      name                      = kubernetes_service_account_v1.agent_orchestration_api.metadata[0].name
      gcp_service_account_email = local.agent_orchestration_api_gcp_service_account_email
    }
    runner = {
      name                      = kubernetes_service_account_v1.agent_orchestration_runner.metadata[0].name
      gcp_service_account_email = local.agent_orchestration_runner_gcp_service_account_email
    }
  }
}

output "feast_apply_environments" {
  description = "GitHub Environment별 Feast apply namespace/KSA/GSA/NetworkPolicy 계약(#424). 각 키의 튜플은 함께 변경해야 한다."
  value = {
    for environment, identity in local.feast_apply_identities : environment => {
      namespace                  = kubernetes_namespace_v1.feast_apply[environment].metadata[0].name
      service_account            = kubernetes_service_account_v1.feast_apply[environment].metadata[0].name
      gcp_service_account_email  = identity.gcp_service_account_email
      ingress_network_policy     = kubernetes_network_policy_v1.feast_apply_ingress[environment].metadata[0].name
      egress_network_policy      = kubernetes_network_policy_v1.feast_apply_egress[environment].metadata[0].name
      redis_psc_egress_permitted = environment == "prod"
    }
  }
}

output "autoresearch_viewer_user_emails" {
  description = "Google accounts granted namespace-scoped view + pods/portforward on the autoresearch namespace (#252)."
  value       = sort(tolist(var.autoresearch_viewer_user_emails))
}

output "rerank_loadtest_contract" {
  description = "Rerank serving load-test namespace, KSA, GSA subjects, RBAC, and NetworkPolicy contract (#482)."
  value = {
    namespace                  = kubernetes_namespace_v1.rerank_loadtest.metadata[0].name
    service_account            = kubernetes_service_account_v1.rerank_loadtest.metadata[0].name
    runner_github_gsa          = local.rerank_loadtest_runner_github_gsa_email
    snapshot_reader_github_gsa = local.rerank_loadtest_snapshot_reader_github_gsa_email
    runner_role                = kubernetes_role_v1.rerank_loadtest_runner.metadata[0].name
    snapshot_reader_role       = kubernetes_role_v1.rerank_loadtest_prometheus_snapshot_reader.metadata[0].name
    ingress_network_policy     = kubernetes_network_policy_v1.rerank_loadtest_ingress.metadata[0].name
    egress_network_policy      = kubernetes_network_policy_v1.rerank_loadtest_egress.metadata[0].name
    resource_quota             = kubernetes_resource_quota_v1.rerank_loadtest.metadata[0].name
    limit_range                = kubernetes_limit_range_v1.rerank_loadtest.metadata[0].name
  }
}
