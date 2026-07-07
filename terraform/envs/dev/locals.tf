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
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "run.googleapis.com",
    "secretmanager.googleapis.com",
    "serviceusage.googleapis.com",
    "servicenetworking.googleapis.com",
    "sqladmin.googleapis.com",
    "storage.googleapis.com",
    "sts.googleapis.com",
  ])

  ar_repo_id = "${local.resource_prefix}-docker"

  sql_instance_name = "${local.resource_prefix}-pg"

  gke_cluster_name                  = "${local.resource_prefix}-gke"
  gke_node_sa_name                  = "${local.resource_prefix}-gke-nodes"
  gke_app_sa_name                   = "${local.resource_prefix}-app"
  gke_node_pool_name                = "dev-default"
  airflow_gke_node_pool_name        = var.airflow_gke_node_pool_name
  airflow_api_k8s_secret_name       = var.airflow_api_k8s_secret_name
  airflow_youtube_api_key_secret_id = "${local.resource_prefix}-youtube-api-key"
  airflow_openrouter_api_secret_id  = "${local.resource_prefix}-openrouter-api-key"
  gke_pods_range_name               = "gke-pods"
  gke_services_range_name           = "gke-services"
  db_password_secret_id             = "${local.resource_prefix}-db-password"
  raw_data_bucket_name              = "${var.project_id}-${local.resource_prefix}-raw-data"
  bigquery_dataset_id               = replace("${local.resource_prefix}_analytics", "-", "_")
  feast_dataset_id                  = "feast_offline_store"
  feast_registry_bucket             = "${var.project_id}-feast-registry"
  feast_staging_bucket              = "${var.project_id}-feast-staging"
  raw_data_prefixes = {
    youtube_raw     = "youtube/raw/"
    users_raw       = "users/raw/"
    action_logs_raw = "action-logs/raw/"
    personas_raw    = "personas/raw/"
  }
  gke_workload_identity_principal = "${var.project_id}.svc.id.goog[${var.gke_app_k8s_namespace}/${var.gke_app_k8s_service_account}]"

  airflow_sa_name                           = "${local.resource_prefix}-airflow"
  airflow_workload_identity_principal       = "${var.project_id}.svc.id.goog[${var.airflow_k8s_namespace}/${var.airflow_k8s_service_account}]"
  airflow_batch_workload_identity_principal = "${var.project_id}.svc.id.goog[${var.airflow_k8s_namespace}/${var.airflow_batch_k8s_service_account}]"
  airflow_dags_bucket_name                  = "${var.project_id}-${local.resource_prefix}-airflow-dags"
  airflow_logs_bucket_name                  = "${var.project_id}-${local.resource_prefix}-airflow-logs"

  cloud_build_bucket_name                   = "${var.project_id}_cloudbuild"
  cloud_build_compute_service_account_email = "${data.google_project.current.number}-compute@developer.gserviceaccount.com"
  proxy_service_name                        = "${local.resource_prefix}-proxy"
  proxy_sa_name                             = "${local.resource_prefix}-proxy"
  # 이미지 미지정 시 버전 태그 예시를 사용한다. 재배포는 proxy_image 값을 새 tag/digest로 바꿔 트리거한다.
  proxy_image = var.proxy_image != "" ? var.proxy_image : "${var.region}-docker.pkg.dev/${var.project_id}/${local.ar_repo_id}/proxy:dev-20260708-001"
}
