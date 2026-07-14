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

output "airflow_deployer_role_binding_name" {
  description = "GitHub Actions deployer의 namespace-scoped admin RoleBinding 이름."
  value       = kubernetes_role_binding_v1.airflow_deployer_admin.metadata[0].name
}
