locals {
  resource_prefix = "${var.name_prefix}-${var.environment}"

  vpc_name        = "${local.resource_prefix}-vpc"
  dev_subnet_name = "${local.resource_prefix}-subnet"
  ssh_iap_tag     = "ssh-iap"

  default_labels = merge(
    {
      environment = var.environment
      managed_by  = "terraform"
      project     = "autoresearch"
      repository  = "autoresearch-infra"
    },
    var.labels
  )

  required_services = toset([
    "artifactregistry.googleapis.com",
    "bigquery.googleapis.com",
    "cloudbuild.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    "container.googleapis.com",
    "dns.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "iap.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "networkconnectivity.googleapis.com",
    "oslogin.googleapis.com",
    "run.googleapis.com",
    "redis.googleapis.com",
    "secretmanager.googleapis.com",
    "serviceconsumermanagement.googleapis.com",
    "serviceusage.googleapis.com",
    "servicenetworking.googleapis.com",
    "sqladmin.googleapis.com",
    "storage.googleapis.com",
    "sts.googleapis.com",
  ])

  ar_repo_id = "${local.resource_prefix}-docker"

  sql_instance_name                    = "${local.resource_prefix}-pg"
  redis_cluster_name                   = "${local.resource_prefix}-redis-cluster"
  redis_psc_subnet_name                = "${local.resource_prefix}-redis-psc"
  redis_service_connection_policy_name = "${local.resource_prefix}-redis-psc"
  redis_server_ca_secret_id            = "${local.resource_prefix}-redis-server-ca"

  gke_cluster_name = "${local.resource_prefix}-gke"
  gke_node_sa_name = "${local.resource_prefix}-gke-nodes"
  gke_app_sa_name  = "${local.resource_prefix}-app"
  mlflow_sa_name   = "${local.resource_prefix}-mlflow"
  # #226: 앱팀이 수동 생성한 기존 버킷명(${project_id}-${name_prefix}-mlflow-artifacts)을
  # 그대로 adopt한다. feast 버킷과 동일하게 project_id를 포함해 전역 유일성 확보.
  mlflow_artifacts_bucket               = "${var.project_id}-${var.name_prefix}-mlflow-artifacts"
  gke_node_pool_name                    = "dev-default"
  airflow_batch_sa_name                 = "${local.resource_prefix}-airflow-batch"
  airflow_youtube_api_key_secret_id     = "${local.resource_prefix}-youtube-api-key"
  airflow_openrouter_api_secret_id      = "${local.resource_prefix}-openrouter-api-key"
  airflow_oauth_client_id_secret_id     = "${local.resource_prefix}-airflow-oauth-client-id"
  airflow_oauth_client_secret_secret_id = "${local.resource_prefix}-airflow-oauth-client-secret"
  gke_pods_range_name                   = "gke-pods"
  gke_services_range_name               = "gke-services"
  db_password_secret_id                 = "${local.resource_prefix}-db-password"
  mlflow_db_password_secret_id          = "${local.resource_prefix}-mlflow-db-password"
  mlflow_oauth_client_secret_secret_id  = "${local.resource_prefix}-mlflow-oauth-client-secret"
  raw_data_bucket_name                  = "${var.project_id}-${local.resource_prefix}-raw-data"
  bigquery_dataset_id                   = replace("${local.resource_prefix}_analytics", "-", "_")
  feast_dataset_id                      = "feast_offline_store"
  feast_registry_bucket                 = "${var.project_id}-feast-registry"
  feast_staging_bucket                  = "${var.project_id}-feast-staging"
  # #238 코드 아카이브 배포 버킷·업로더 SA. 버킷명은 이슈 예시(project_id 포함, 전역 유일).
  code_artifacts_bucket = "${var.project_id}-code-artifacts"
  code_uploader_sa_name = "${local.resource_prefix}-code-uploader"
  raw_data_prefixes = {
    youtube_raw            = "data_lake/youtube_trending_kr/"
    users_raw              = "asset/virtual_user/"
    action_logs_raw        = "data_lake/action_log/"
    personas_raw           = "data/raw/personas/"
    youtube_trending_kr    = "data_lake/youtube_trending_kr/"
    action_logs            = "data_lake/action_log/"
    action_log_quarantine  = "data_lake/action_log_quarantine/"
    virtual_users          = "asset/virtual_user/"
    personas_raw_snapshots = "data/raw/personas/"
  }
  gke_workload_identity_principal = "${var.project_id}.svc.id.goog[${var.gke_app_k8s_namespace}/${var.gke_app_k8s_service_account}]"

  mlflow_workload_identity_principal = "${var.project_id}.svc.id.goog[${var.mlflow_k8s_namespace}/${var.mlflow_k8s_service_account}]"

  airflow_sa_name                               = "${local.resource_prefix}-airflow"
  airflow_workload_identity_principal           = "${var.project_id}.svc.id.goog[${var.airflow_k8s_namespace}/${var.airflow_k8s_service_account}]"
  airflow_scheduler_workload_identity_principal = "${var.project_id}.svc.id.goog[${var.airflow_k8s_namespace}/${var.airflow_scheduler_k8s_service_account}]"
  airflow_batch_workload_identity_principal     = "${var.project_id}.svc.id.goog[${var.airflow_k8s_namespace}/${var.airflow_batch_k8s_service_account}]"
  airflow_dags_bucket_name                      = "${var.project_id}-${local.resource_prefix}-airflow-dags"
  airflow_logs_bucket_name                      = "${var.project_id}-${local.resource_prefix}-airflow-logs"

  cloud_build_bucket_name                   = "${var.project_id}_cloudbuild"
  cloud_build_compute_service_account_email = "${data.google_project.current.number}-compute@developer.gserviceaccount.com"
  proxy_service_name                        = "${local.resource_prefix}-proxy"
  proxy_sa_name                             = "${local.resource_prefix}-proxy"
  # 이미지 미지정 시 버전 태그 예시를 사용한다. 재배포는 proxy_image 값을 새 tag/digest로 바꿔 트리거한다.
  proxy_image = var.proxy_image != "" ? var.proxy_image : "${var.region}-docker.pkg.dev/${var.project_id}/${local.ar_repo_id}/proxy:dev-20260708-001"

  bastion_name = "${local.resource_prefix}-bastion"

  vault_sa_name                     = "${local.resource_prefix}-vault"
  vault_workload_identity_principal = "${var.project_id}.svc.id.goog[${var.vault_k8s_namespace}/${var.vault_k8s_service_account}]"

  es_snapshot_bucket_name        = "${var.project_id}-${local.resource_prefix}-es-snapshots"
  es_snapshot_sa_name            = "${local.resource_prefix}-es-snapshot"
  es_workload_identity_principal = "${var.project_id}.svc.id.goog[${var.elastic_k8s_namespace}/${var.es_k8s_service_account}]"
}
