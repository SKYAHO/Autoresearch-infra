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
    # #280 BigQuery ML remote model이 호출하는 Vertex AI
    "aiplatform.googleapis.com",
    "artifactregistry.googleapis.com",
    "bigquery.googleapis.com",
    # #280 BigQuery ↔ Vertex AI CLOUD_RESOURCE connection
    "bigqueryconnection.googleapis.com",
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

  gke_cluster_name           = "${local.resource_prefix}-gke"
  gke_node_sa_name           = "${local.resource_prefix}-gke-nodes"
  gke_app_sa_name            = "${local.resource_prefix}-app"
  experiment_runtime_sa_name = "${local.resource_prefix}-exp-runtime"
  mlflow_sa_name             = "${local.resource_prefix}-mlflow"
  # Google service account account_id는 30자 제한이 있으므로 workload의 긴
  # Kubernetes 이름 대신 짧은 orch-api/orch-runner 식별자를 사용한다.
  agent_orchestration_api_sa_name    = "${local.resource_prefix}-orch-api"
  agent_orchestration_runner_sa_name = "${local.resource_prefix}-orch-runner"
  # #539 실험 브랜치 Job launcher. `-orch-launcher`는 account_id 상한 30자를 정확히
  # 채워 여유가 없으므로 `-orch-launch`로 줄인다(28자).
  agent_orchestration_launcher_sa_name = "${local.resource_prefix}-orch-launch"
  # 실험 Job은 API·Codex Runner와 다른 GSA를 사용한다. 결과 버킷 object 생성만
  # 허용하고 Secret Manager·Cloud SQL·Kubernetes API 권한은 부여하지 않는다.
  experiment_job_sa_name         = "${local.resource_prefix}-exp-job"
  experiment_results_bucket_name = "${var.project_id}-${local.resource_prefix}-experiment-results"
  # #226: 앱팀이 수동 생성한 기존 버킷명(${project_id}-${name_prefix}-mlflow-artifacts)을
  # 그대로 adopt한다. feast 버킷과 동일하게 project_id를 포함해 전역 유일성 확보.
  mlflow_artifacts_bucket                            = "${var.project_id}-${var.name_prefix}-mlflow-artifacts"
  mlflow_training_snapshot_prefix                    = "training-snapshots/"
  gke_node_pool_name                                 = "dev-default"
  airflow_batch_sa_name                              = "${local.resource_prefix}-airflow-batch"
  airflow_youtube_api_key_secret_id                  = "${local.resource_prefix}-youtube-api-key"
  airflow_openrouter_api_secret_id                   = "${local.resource_prefix}-openrouter-api-key"
  airflow_oauth_client_id_secret_id                  = "${local.resource_prefix}-airflow-oauth-client-id"
  airflow_oauth_client_secret_secret_id              = "${local.resource_prefix}-airflow-oauth-client-secret"
  gke_pods_range_name                                = "gke-pods"
  gke_services_range_name                            = "gke-services"
  db_password_secret_id                              = "${local.resource_prefix}-db-password"
  mlflow_db_password_secret_id                       = "${local.resource_prefix}-mlflow-db-password"
  agent_orchestration_db_password_secret_id          = "${local.resource_prefix}-agent-orchestration-db-password"
  agent_orchestration_codex_auth_bootstrap_secret_id = "${local.resource_prefix}-agent-orchestration-codex-auth-bootstrap"
  mlflow_oauth_client_secret_secret_id               = "${local.resource_prefix}-mlflow-oauth-client-secret"
  mlflow_oauth_client_id_secret_id                   = "${local.resource_prefix}-mlflow-oauth-client-id"
  raw_data_bucket_name                               = "${var.project_id}-${local.resource_prefix}-raw-data"
  bigquery_dataset_id                                = replace("${local.resource_prefix}_analytics", "-", "_")
  feast_dataset_id                                   = "feast_offline_store"
  # #285 raw layer 전용 dataset. feast_offline_store는 Feast 피처 테이블 전용으로 남긴다.
  data_lake_raw_dataset_id  = "data_lake_raw"
  feast_registry_bucket     = "${var.project_id}-feast-registry"
  feast_staging_bucket      = "${var.project_id}-feast-staging"
  feast_dev_registry_bucket = "${var.project_id}-feast-registry-dev"
  feast_dev_staging_bucket  = "${var.project_id}-feast-staging-dev"

  # #424 Feast apply의 prod 경로는 기존 버킷 루트를 그대로 보존한다. dev는
  # 별도 버킷 루트를 사용해 bucket-level IAM에서 환경 경계를 강제한다.
  feast_dev_dataset_id                  = "feast_offline_store_dev"
  feast_prod_registry_path              = "gs://${local.feast_registry_bucket}/registry.db"
  feast_prod_staging_location           = "gs://${local.feast_staging_bucket}/"
  feast_dev_registry_path               = "gs://${local.feast_dev_registry_bucket}/registry.db"
  feast_dev_staging_location            = "gs://${local.feast_dev_staging_bucket}/"
  experiment_runtime_experiments_prefix = "experiments/"
  # #238 코드 아카이브 배포 버킷·업로더 SA. 버킷명은 이슈 예시(project_id 포함, 전역 유일).
  code_artifacts_bucket          = "${var.project_id}-code-artifacts"
  code_uploader_sa_name          = "${local.resource_prefix}-code-uploader"
  experiment_runtime_code_prefix = "code/"
  # #577 학습 데이터셋 스냅샷 prefix. 이 버킷은 원래 코드 아카이브 전용이었으나
  # (`code/` prefix) 같은 성격의 두 번째 입력물을 받는다 — 파드 밖에서 만들어 올리고
  # 파드는 읽기만 하는 불변 산출물이다. `experiment-job` GSA의 read는 이 prefix로만
  # 좁혀 `code/` 아카이브와 서로 침범하지 않게 한다.
  #
  # 이 아래 레이아웃은 애플리케이션의 스냅샷 스토어 계약을 따른다
  # (`SKYAHO/Autoresearch`의 `docs/specs/2026-08-04-training-dataset-snapshot-store.md`).
  #   <prefix>by-hash/<dataset_sha256>/training_dataset.csv
  #   <prefix>by-hash/<dataset_sha256>/snapshot_manifest.json
  #   <prefix>by-date/dt=<events_end_date>/<feature_service>.json
  training_snapshot_prefix = "training-snapshots/"
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
    # #522 앱 저장소 PR #517(`Autoresearch`)이 action log 원자적 게시의 임시
    # staging 객체를 파티션 안(`<dest>.staging-<uuid>`)에서 버킷 루트의 이
    # 고정 prefix(`_publish_staging/<uuid>.tmp`)로 옮겼다. 삭제 IAM 조건도
    # 이 prefix를 대상으로 삼아야 한다 — 이전처럼 action_logs_raw prefix에
    # 스코프하면 앱이 실제로 만드는 staging 객체를 지울 수 없다(라이브
    # 확인 결과 고아 객체 1개 발생, 2026-08-05 조사).
    publish_staging_raw = "_publish_staging/"
  }
  gke_workload_identity_principal                = "${var.project_id}.svc.id.goog[${var.gke_app_k8s_namespace}/${var.gke_app_k8s_service_account}]"
  experiment_runtime_workload_identity_principal = "${var.project_id}.svc.id.goog[${var.experiment_runtime_k8s_namespace}/${var.experiment_runtime_k8s_service_account}]"

  agent_orchestration_api_workload_identity_principal      = "${var.project_id}.svc.id.goog[${var.agent_orchestration_k8s_namespace}/${var.agent_orchestration_api_k8s_service_account}]"
  agent_orchestration_runner_workload_identity_principal   = "${var.project_id}.svc.id.goog[${var.agent_orchestration_k8s_namespace}/${var.agent_orchestration_runner_k8s_service_account}]"
  agent_orchestration_launcher_workload_identity_principal = "${var.project_id}.svc.id.goog[${var.agent_orchestration_k8s_namespace}/${var.agent_orchestration_launcher_k8s_service_account}]"
  experiment_job_workload_identity_principal               = "${var.project_id}.svc.id.goog[${var.experiment_job_k8s_namespace}/${var.experiment_job_k8s_service_account}]"

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

  es_snapshot_bucket_name        = "${var.project_id}-${local.resource_prefix}-es-snapshots"
  es_snapshot_sa_name            = "${local.resource_prefix}-es-snapshot"
  es_workload_identity_principal = "${var.project_id}.svc.id.goog[${var.elastic_k8s_namespace}/${var.es_k8s_service_account}]"

  # #533 ARC 컨트롤러 매니저 Pod의 Workload Identity subject. 러너(listener/ephemeral
  # runner) Pod 자체는 GCP API를 직접 호출하지 않으므로 이 GSA를 공유하지 않는다.
  actions_runner_controller_sa_name                     = "${local.resource_prefix}-runner"
  actions_runner_controller_workload_identity_principal = "${var.project_id}.svc.id.goog[${var.actions_runner_namespace}/${var.actions_runner_controller_ksa}]"

  # #424 검증된 환경 map에서 WI subject를 파생한다. Task 2의 환경별 GSA IAM
  # binding이 이 map을 직접 소비하므로 namespace/KSA 계약이 변경되면 같은
  # 환경의 subject만 함께 바뀐다.
  feast_apply_workload_identity_principals = {
    for environment, identity in var.feast_apply_kubernetes_identities :
    environment => "${var.project_id}.svc.id.goog[${identity.namespace}/${identity.service_account}]"
  }
}
