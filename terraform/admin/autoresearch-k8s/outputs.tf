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

output "autoresearch_viewer_user_emails" {
  description = "Google accounts granted namespace-scoped view + pods/portforward on the autoresearch namespace (#252)."
  value       = sort(tolist(var.autoresearch_viewer_user_emails))
}
