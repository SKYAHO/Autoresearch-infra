output "airflow_namespace" {
  description = "Airflow Kubernetes namespace."
  value       = kubernetes_namespace_v1.airflow.metadata[0].name
}

output "airflow_service_account" {
  description = "Airflow Kubernetes service account."
  value       = kubernetes_service_account_v1.airflow.metadata[0].name
}

output "installer_role_binding_names" {
  description = "Namespace-scoped installer admin RoleBinding names."
  value       = [for binding in kubernetes_role_binding_v1.installer_admin : binding.metadata[0].name]
}
