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

output "feast_apply_namespace" {
  description = "Namespace dedicated to the feast apply Job (#346). Contract value for SKYAHO/Autoresearch feast-apply.yml."
  value       = kubernetes_namespace_v1.feast_apply.metadata[0].name
}

output "feast_apply_service_account" {
  description = "Kubernetes service account used by the feast apply Job pod (#346). Job spec serviceAccountName."
  value       = kubernetes_service_account_v1.feast_apply.metadata[0].name
}

output "feast_apply_egress_network_policy" {
  description = "NetworkPolicy allowing feast apply egress: DNS, Redis Cluster PSC topology, GKE metadata, HTTPS (#346)."
  value       = kubernetes_network_policy_v1.feast_apply_egress.metadata[0].name
}

output "autoresearch_viewer_user_emails" {
  description = "Google accounts granted namespace-scoped view + pods/portforward on the autoresearch namespace (#252)."
  value       = sort(tolist(var.autoresearch_viewer_user_emails))
}
