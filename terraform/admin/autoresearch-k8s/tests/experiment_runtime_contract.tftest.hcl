mock_provider "google" {}
mock_provider "kubernetes" {}

override_data {
  target = data.kubernetes_service_v1.experiment_runtime_kube_dns
  values = {
    spec = [{
      cluster_ip = "172.16.128.10"
      type       = "ClusterIP"
    }]
  }
}

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
