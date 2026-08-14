# Rerank load-test RBAC contract. Keep this separate from the experiment runtime
# contract so each test file describes one admin root boundary.
variables {
  project_id            = "autoresearch-505505"
  region                = "asia-northeast3"
  zone                  = "asia-northeast3-a"
  gke_cluster_name      = "autoresearch-dev-gke"
  resource_prefix       = "autoresearch-dev"
  private_services_cidr = "192.168.0.0/20"
  cluster_services_cidr = "172.16.128.0/24"
}

mock_provider "google" {}
mock_provider "kubernetes" {}

override_data {
  target = data.kubernetes_service_v1.kube_dns
  values = {
    spec = [{
      cluster_ip = "172.16.128.10"
      type       = "ClusterIP"
    }]
  }
}

override_data {
  target = data.kubernetes_service_v1.autoresearch_serving
  values = {
    spec = [{
      cluster_ip = "172.16.128.20"
      type       = "ClusterIP"
    }]
  }
}

run "bind_prometheus_snapshot_reader_to_exact_proxy_resource" {
  command = plan

  variables {
    project_id            = "valid-project"
    private_services_cidr = "192.168.0.0/20"
  }

  assert {
    condition = (
      length(kubernetes_role_v1.rerank_loadtest_prometheus_snapshot_reader.rule) == 1 &&
      length(kubernetes_role_v1.rerank_loadtest_prometheus_snapshot_reader.rule[0].resource_names) == 1 &&
      contains(tolist(kubernetes_role_v1.rerank_loadtest_prometheus_snapshot_reader.rule[0].resource_names), "http:kube-prometheus-stack-prometheus:9090")
    )
    error_message = "The Prometheus snapshot Role must allow only the full Kubernetes services/proxy resource name used by kubectl get --raw."
  }
}
