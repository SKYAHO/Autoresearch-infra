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

run "reject_runtime_gsa_short_account_id" {
  command = plan

  variables {
    project_id                                   = "valid-project"
    private_services_cidr                        = "192.168.0.0/20"
    experiment_runtime_gcp_service_account_email = "short@valid-project.iam.gserviceaccount.com"
  }

  expect_failures = [var.experiment_runtime_gcp_service_account_email]
}

run "reject_runtime_gsa_long_account_id" {
  command = plan

  variables {
    project_id                                   = "valid-project"
    private_services_cidr                        = "192.168.0.0/20"
    experiment_runtime_gcp_service_account_email = "abcdefghijklmnopqrstuvwxyz12345@valid-project.iam.gserviceaccount.com"
  }

  expect_failures = [var.experiment_runtime_gcp_service_account_email]
}

run "reject_runtime_gsa_account_id_starting_with_digit" {
  command = plan

  variables {
    project_id                                   = "valid-project"
    private_services_cidr                        = "192.168.0.0/20"
    experiment_runtime_gcp_service_account_email = "1invalid@valid-project.iam.gserviceaccount.com"
  }

  expect_failures = [var.experiment_runtime_gcp_service_account_email]
}

run "reject_runtime_gsa_account_id_ending_with_hyphen" {
  command = plan

  variables {
    project_id                                   = "valid-project"
    private_services_cidr                        = "192.168.0.0/20"
    experiment_runtime_gcp_service_account_email = "invalid-@valid-project.iam.gserviceaccount.com"
  }

  expect_failures = [var.experiment_runtime_gcp_service_account_email]
}

run "reject_airflow_gsa_invalid_project_id" {
  command = plan

  variables {
    project_id                        = "valid-project"
    private_services_cidr             = "192.168.0.0/20"
    airflow_gcp_service_account_email = "valid-account@bad_project.iam.gserviceaccount.com"
  }

  expect_failures = [var.airflow_gcp_service_account_email]
}

run "reject_airflow_gsa_short_project_id" {
  command = plan

  variables {
    project_id                        = "valid-project"
    private_services_cidr             = "192.168.0.0/20"
    airflow_gcp_service_account_email = "valid-account@short.iam.gserviceaccount.com"
  }

  expect_failures = [var.airflow_gcp_service_account_email]
}

run "reject_airflow_gsa_long_project_id" {
  command = plan

  variables {
    project_id                        = "valid-project"
    private_services_cidr             = "192.168.0.0/20"
    airflow_gcp_service_account_email = "valid-account@abcdefghijklmnopqrstuvwxyz12345.iam.gserviceaccount.com"
  }

  expect_failures = [var.airflow_gcp_service_account_email]
}

run "reject_airflow_gsa_project_id_starting_with_digit" {
  command = plan

  variables {
    project_id                        = "valid-project"
    private_services_cidr             = "192.168.0.0/20"
    airflow_gcp_service_account_email = "valid-account@1invalid-project.iam.gserviceaccount.com"
  }

  expect_failures = [var.airflow_gcp_service_account_email]
}

run "reject_airflow_gsa_project_id_ending_with_hyphen" {
  command = plan

  variables {
    project_id                        = "valid-project"
    private_services_cidr             = "192.168.0.0/20"
    airflow_gcp_service_account_email = "valid-account@invalid-project-.iam.gserviceaccount.com"
  }

  expect_failures = [var.airflow_gcp_service_account_email]
}

run "accept_valid_gsa_overrides" {
  command = plan

  variables {
    project_id                                   = "valid-project"
    private_services_cidr                        = "192.168.0.0/20"
    experiment_runtime_gcp_service_account_email = "valid-runtime@valid-project.iam.gserviceaccount.com"
    airflow_gcp_service_account_email            = "valid-airflow@valid-project.iam.gserviceaccount.com"
  }

  assert {
    condition     = output.experiment_runtime_kubernetes_contract.gcp_service_account_email == "valid-runtime@valid-project.iam.gserviceaccount.com"
    error_message = "A structurally valid runtime GSA override must remain unchanged."
  }
}

run "derive_task1_runtime_gsa_default" {
  command = plan

  variables {
    project_id            = "valid-project"
    private_services_cidr = "192.168.0.0/20"
  }

  assert {
    condition     = output.experiment_runtime_kubernetes_contract.gcp_service_account_email == "autoresearch-dev-exp-runtime@valid-project.iam.gserviceaccount.com"
    error_message = "The admin root default runtime GSA must match the Task 1 dev root name."
  }

  assert {
    condition     = output.experiment_runtime_kubernetes_contract.job_creation_enabled == false
    error_message = "The experiment runtime contract must remain fail-closed."
  }
}
