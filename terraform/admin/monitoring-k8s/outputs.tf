output "monitoring_namespace" {
  description = "Prometheus/Grafana Kubernetes namespace."
  value       = kubernetes_namespace_v1.monitoring.metadata[0].name
}
