output "monitoring_namespace" {
  description = "Prometheus/Grafana Kubernetes namespace."
  value       = kubernetes_namespace_v1.monitoring.metadata[0].name
}

output "kube_prometheus_stack_release_name" {
  description = "Prometheus/Grafana Helm release name."
  value       = helm_release.kube_prometheus_stack.name
}

output "kube_prometheus_stack_chart_version" {
  description = "Pinned kube-prometheus-stack Helm chart version."
  value       = helm_release.kube_prometheus_stack.version
}

output "monitoring_port_forward_role_binding_names" {
  description = "Monitoring namespace RoleBinding names for allowlisted port-forward users."
  value       = [for binding in kubernetes_role_binding_v1.monitoring_port_forward : binding.metadata[0].name]
}
