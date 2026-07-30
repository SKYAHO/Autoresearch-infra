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
