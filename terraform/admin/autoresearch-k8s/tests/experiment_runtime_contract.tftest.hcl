# 좌표 변수는 카탈로그(config/environments/dev/environment.yaml)가 공급하며 각
# root의 variables.tf에는 default가 없다(#491). `terraform test`는 .auto.tfvars를
# 자동 로드하지 않으므로, 여기서 명시하지 않으면 전 run이 "No value for required
# variable"로 실패한다. 값은 카탈로그와 동일하게 유지한다.
variables {
  project_id            = "autoresearch-503903"
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

run "bind_observer_to_single_airflow_ksa" {
  command = plan

  variables {
    project_id            = "valid-project"
    private_services_cidr = "192.168.0.0/20"
  }

  assert {
    condition = (
      length(kubernetes_role_binding_v1.experiment_runtime_airflow_observer.subject) == 1 &&
      kubernetes_role_binding_v1.experiment_runtime_airflow_observer.subject[0].kind == "ServiceAccount" &&
      kubernetes_role_binding_v1.experiment_runtime_airflow_observer.subject[0].name == "airflow" &&
      kubernetes_role_binding_v1.experiment_runtime_airflow_observer.subject[0].namespace == "airflow"
    )
    error_message = "The observer RoleBinding must grant only the in-cluster airflow/airflow ServiceAccount."
  }

  assert {
    condition     = !contains(flatten([for rule in kubernetes_role_v1.experiment_runtime_airflow_observer.rule : rule.verbs]), "create")
    error_message = "The Airflow observer Role must not grant jobs.create."
  }

  assert {
    condition = (
      output.experiment_runtime_kubernetes_contract.airflow_observer_subject.kind == "ServiceAccount" &&
      output.experiment_runtime_kubernetes_contract.airflow_observer_subject.name == "airflow" &&
      output.experiment_runtime_kubernetes_contract.airflow_observer_subject.namespace == "airflow"
    )
    error_message = "The published observer subject must match the RoleBinding subject."
  }
}

run "reject_runtime_gsa_whitespace_override" {
  command = plan

  variables {
    project_id                                   = "valid-project"
    private_services_cidr                        = "192.168.0.0/20"
    experiment_runtime_gcp_service_account_email = "   "
  }

  expect_failures = [var.experiment_runtime_gcp_service_account_email]
}

run "reject_runtime_gsa_invalid_account_id" {
  command = plan

  variables {
    project_id                                   = "valid-project"
    private_services_cidr                        = "192.168.0.0/20"
    experiment_runtime_gcp_service_account_email = "bad!account@valid-project.iam.gserviceaccount.com"
  }

  expect_failures = [var.experiment_runtime_gcp_service_account_email]
}

run "reject_runtime_gsa_invalid_account_id_length" {
  command = plan

  variables {
    project_id                                   = "valid-project"
    private_services_cidr                        = "192.168.0.0/20"
    experiment_runtime_gcp_service_account_email = "short@valid-project.iam.gserviceaccount.com"
  }

  expect_failures = [var.experiment_runtime_gcp_service_account_email]
}

run "reject_runtime_gsa_invalid_account_id_boundaries" {
  command = plan

  variables {
    project_id                                   = "valid-project"
    private_services_cidr                        = "192.168.0.0/20"
    experiment_runtime_gcp_service_account_email = "1invalid-@valid-project.iam.gserviceaccount.com"
  }

  expect_failures = [var.experiment_runtime_gcp_service_account_email]
}

run "accept_valid_runtime_gsa_override" {
  command = plan

  variables {
    project_id                                   = "valid-project"
    private_services_cidr                        = "192.168.0.0/20"
    experiment_runtime_gcp_service_account_email = "valid-runtime@valid-project.iam.gserviceaccount.com"
  }

  assert {
    condition     = output.experiment_runtime_kubernetes_contract.gcp_service_account_email == "valid-runtime@valid-project.iam.gserviceaccount.com"
    error_message = "A structurally valid runtime GSA override must remain unchanged."
  }
}

run "preserve_task1_runtime_gsa_and_fail_closed_contract" {
  command = plan

  variables {
    project_id            = "valid-project"
    private_services_cidr = "192.168.0.0/20"
  }

  assert {
    condition     = output.experiment_runtime_kubernetes_contract.gcp_service_account_email == "autoresearch-dev-exp-runtime@valid-project.iam.gserviceaccount.com"
    error_message = "The admin root runtime GSA default must match the Task 1 dev root name."
  }

  assert {
    condition     = output.experiment_runtime_kubernetes_contract.job_creation_enabled == false
    error_message = "The experiment runtime contract must remain fail-closed."
  }
}

run "bind_prometheus_snapshot_reader_to_proxy_resource" {
  command = plan

  variables {
    project_id            = "valid-project"
    private_services_cidr = "192.168.0.0/20"
  }

  assert {
    condition = contains(
      flatten([
        for rule in kubernetes_role_v1.rerank_loadtest_prometheus_snapshot_reader.rule : rule.resource_names
      ]),
      "http:kube-prometheus-stack-prometheus:9090"
    )
    error_message = "The Prometheus snapshot Role must allow the full Kubernetes services/proxy resource name used by kubectl get --raw."
  }
}
