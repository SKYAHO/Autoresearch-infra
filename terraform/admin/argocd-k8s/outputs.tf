output "argocd_namespace" {
  description = "ArgoCD Kubernetes namespace."
  value       = kubernetes_namespace_v1.argocd.metadata[0].name
}

output "argocd_values_file_path" {
  description = "Module-relative ArgoCD Helm values file path."
  value       = var.argocd_values_file_path
}

output "argo_cd_release_name" {
  description = "ArgoCD Helm release name."
  value       = helm_release.argo_cd.name
}

output "argo_cd_chart_version" {
  description = "Pinned argo-cd Helm chart version."
  value       = helm_release.argo_cd.version
}
