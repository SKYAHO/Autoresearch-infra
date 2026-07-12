output "vault_namespace" {
  description = "Vault Kubernetes namespace."
  value       = kubernetes_namespace_v1.vault.metadata[0].name
}

output "vault_release_name" {
  description = "Vault Helm release name."
  value       = helm_release.vault.name
}

output "vault_chart_version" {
  description = "Pinned vault Helm chart version."
  value       = helm_release.vault.version
}
