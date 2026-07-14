output "monitoring_namespace" {
  description = "Prometheus/Grafana Kubernetes namespace."
  value       = kubernetes_namespace_v1.monitoring.metadata[0].name
}

# #183 kube_prometheus_stack_* output은 ArgoCD 이관으로 제거됨
# (chart/버전은 이제 deploy/monitoring umbrella chart가 관리).

output "monitoring_port_forward_role_binding_names" {
  description = "Monitoring namespace RoleBinding names for allowlisted port-forward users."
  value       = [for binding in kubernetes_role_binding_v1.monitoring_port_forward : binding.metadata[0].name]
}
