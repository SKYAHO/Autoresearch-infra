output "elastic_namespace" {
  description = "ECK/Elasticsearch/Kibana Kubernetes namespace."
  value       = kubernetes_namespace_v1.elastic.metadata[0].name
}

output "eck_release_name" {
  description = "ECK operator Helm release name."
  value       = helm_release.eck_operator.name
}

output "eck_chart_version" {
  description = "Pinned eck-operator Helm chart version."
  value       = helm_release.eck_operator.version
}
