output "rollouts_namespace" {
  description = "Argo Rollouts Kubernetes namespace."
  value       = kubernetes_namespace_v1.argo_rollouts.metadata[0].name
}

output "rollouts_release_name" {
  description = "Argo Rollouts Helm release name."
  value       = helm_release.argo_rollouts.name
}

output "rollouts_chart_version" {
  description = "Pinned argo-rollouts Helm chart version."
  value       = helm_release.argo_rollouts.version
}
