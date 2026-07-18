output "mlflow_namespace" {
  description = "MLflow tracking server Kubernetes namespace."
  value       = kubernetes_namespace_v1.mlflow.metadata[0].name
}

output "mlflow_service_account" {
  description = "MLflow Workload Identity Kubernetes service account."
  value       = kubernetes_service_account_v1.mlflow.metadata[0].name
}

output "mlflow_egress_network_policy" {
  description = "NetworkPolicy allowing minimum MLflow egress (Cloud SQL, GCS/API, DNS, WI metadata)."
  value       = kubernetes_network_policy_v1.mlflow_egress.metadata[0].name
}

output "mlflow_viewer_user_emails" {
  description = "Google accounts granted namespace-scoped view + pods/portforward on the mlflow namespace (#236)."
  value       = sort(tolist(var.mlflow_viewer_user_emails))
}
