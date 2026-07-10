output "argocd_namespace" {
  description = "ArgoCD Kubernetes namespace."
  value       = kubernetes_namespace_v1.argocd.metadata[0].name
}

output "argocd_values_file_path" {
  description = "Repository-relative ArgoCD Helm values scaffold path."
  value       = var.argocd_values_file_path
}
