output "rollouts_namespace" {
  description = "Argo Rollouts Kubernetes namespace."
  value       = kubernetes_namespace_v1.argo_rollouts.metadata[0].name
}
