output "app_namespace" {
  description = "Autoresearch application Kubernetes namespace."
  value       = kubernetes_namespace_v1.autoresearch.metadata[0].name
}

output "app_service_account" {
  description = "Autoresearch Workload Identity Kubernetes service account."
  value       = kubernetes_service_account_v1.app.metadata[0].name
}

output "app_egress_network_policy" {
  description = "NetworkPolicy that allows minimum application egress including Redis Cluster PSC topology traffic."
  value       = kubernetes_network_policy_v1.app_egress.metadata[0].name
}

output "agent_orchestration_service_accounts" {
  description = "Agent Orchestration API와 Codex Runner의 분리된 Workload Identity Kubernetes service account."
  value = {
    api = {
      name                      = kubernetes_service_account_v1.agent_orchestration_api.metadata[0].name
      gcp_service_account_email = local.agent_orchestration_api_gcp_service_account_email
    }
    runner = {
      name                      = kubernetes_service_account_v1.agent_orchestration_runner.metadata[0].name
      gcp_service_account_email = local.agent_orchestration_runner_gcp_service_account_email
    }
    # #539 실험 브랜치 launcher. dev root output의 launcher 좌표와 정확히 같아야 한다.
    launcher = {
      name                      = kubernetes_service_account_v1.agent_orchestration_launcher.metadata[0].name
      gcp_service_account_email = local.agent_orchestration_launcher_gcp_service_account_email
    }
    # #616 실험 로그 수집기. dev root output의 log_collector 좌표와 정확히 같아야 한다.
    log_collector = {
      name                      = kubernetes_service_account_v1.agent_orchestration_log_collector.metadata[0].name
      gcp_service_account_email = local.agent_orchestration_log_collector_gcp_service_account_email
    }
  }
}

output "feast_apply_environments" {
  description = "GitHub Environment별 Feast apply namespace/KSA/GSA/NetworkPolicy 계약(#424). 각 키의 튜플은 함께 변경해야 한다."
  value = {
    for environment, identity in local.feast_apply_identities : environment => {
      namespace                  = kubernetes_namespace_v1.feast_apply[environment].metadata[0].name
      service_account            = kubernetes_service_account_v1.feast_apply[environment].metadata[0].name
      gcp_service_account_email  = identity.gcp_service_account_email
      ingress_network_policy     = kubernetes_network_policy_v1.feast_apply_ingress[environment].metadata[0].name
      egress_network_policy      = kubernetes_network_policy_v1.feast_apply_egress[environment].metadata[0].name
      redis_psc_egress_permitted = environment == "prod"
    }
  }
}

output "autoresearch_viewer_user_emails" {
  description = "Google accounts granted namespace-scoped view + pods/portforward on the autoresearch namespace (#252)."
  value       = sort(tolist(var.autoresearch_viewer_user_emails))
}

output "rerank_loadtest_contract" {
  description = "Rerank serving load-test namespace, KSA, GSA subjects, RBAC, and NetworkPolicy contract (#482)."
  value = {
    namespace                  = kubernetes_namespace_v1.rerank_loadtest.metadata[0].name
    service_account            = kubernetes_service_account_v1.rerank_loadtest.metadata[0].name
    runner_github_gsa          = local.rerank_loadtest_runner_github_gsa_email
    snapshot_reader_github_gsa = local.rerank_loadtest_snapshot_reader_github_gsa_email
    runner_role                = kubernetes_role_v1.rerank_loadtest_runner.metadata[0].name
    snapshot_reader_role       = kubernetes_role_v1.rerank_loadtest_prometheus_snapshot_reader.metadata[0].name
    ingress_network_policy     = kubernetes_network_policy_v1.rerank_loadtest_ingress.metadata[0].name
    egress_network_policy      = kubernetes_network_policy_v1.rerank_loadtest_egress.metadata[0].name
    resource_quota             = kubernetes_resource_quota_v1.rerank_loadtest.metadata[0].name
    limit_range                = kubernetes_limit_range_v1.rerank_loadtest.metadata[0].name
  }
}

output "experiment_job_contract" {
  description = "Auto Research 실험 Job namespace·KSA·GSA·RBAC·NetworkPolicy 계약. Job 생성 주체는 #539에서 API KSA에서 launcher KSA로 옮겼고, API는 상태 조회만 유지한다."
  value = {
    namespace                 = kubernetes_namespace_v1.experiment_jobs.metadata[0].name
    service_account           = kubernetes_service_account_v1.experiment_job.metadata[0].name
    gcp_service_account_email = local.experiment_job_gcp_service_account_email
    api_observer_role         = kubernetes_role_v1.experiment_job_observer.metadata[0].name
    launcher_service_account  = kubernetes_service_account_v1.agent_orchestration_launcher.metadata[0].name
    # #616 observer Role을 함께 갖는 두 번째 주체. Job **생성** Role은 갖지 않는다.
    log_collector_service_account = kubernetes_service_account_v1.agent_orchestration_log_collector.metadata[0].name
    launcher_job_creation_enabled = var.enable_experiment_job_creation
    ingress_network_policy        = kubernetes_network_policy_v1.experiment_jobs_ingress.metadata[0].name
    egress_network_policy         = kubernetes_network_policy_v1.experiment_jobs_egress.metadata[0].name
    # #539 branch-bootstrap Pod에만 추가로 적용되는 공개 443 egress.
    branch_bootstrap_egress_network_policy = kubernetes_network_policy_v1.experiment_jobs_branch_bootstrap_egress.metadata[0].name
    resource_quota                         = kubernetes_resource_quota_v1.experiment_jobs.metadata[0].name
    limit_range                            = kubernetes_limit_range_v1.experiment_jobs.metadata[0].name
  }
}

output "experiment_runtime_kubernetes_contract" {
  description = "Paired Feast experiment runtime의 Kubernetes 격리 좌표와 fail-closed Job 생성 계약."
  value = {
    namespace                 = kubernetes_namespace_v1.experiment_runtime.metadata[0].name
    service_account           = kubernetes_service_account_v1.experiment_runtime.metadata[0].name
    gcp_service_account_email = local.experiment_runtime_gcp_service_account_email
    airflow_observer_role     = kubernetes_role_v1.experiment_runtime_airflow_observer.metadata[0].name
    airflow_observer_subject = {
      kind      = "ServiceAccount"
      name      = var.airflow_k8s_service_account
      namespace = var.airflow_k8s_namespace
    }
    ingress_network_policy  = kubernetes_network_policy_v1.experiment_runtime_ingress.metadata[0].name
    egress_network_policy   = kubernetes_network_policy_v1.experiment_runtime_egress.metadata[0].name
    resource_quota          = kubernetes_resource_quota_v1.experiment_runtime.metadata[0].name
    limit_range             = kubernetes_limit_range_v1.experiment_runtime.metadata[0].name
    private_googleapis_cidr = var.private_googleapis_cidr
    job_creation_enabled    = false
  }
}
