variable "project_id" {
  description = "GCP project id for the dev environment."
  type        = string
}

variable "region" {
  description = "Default GCP region for dev resources."
  type        = string
}

variable "zone" {
  description = "Default GCP zone for zonal dev resources."
  type        = string
}

variable "environment" {
  description = "Deployment environment name."
  type        = string
  default     = "dev"

  validation {
    condition     = var.environment == "dev"
    error_message = "This Terraform root module is only for the dev environment."
  }
}

variable "name_prefix" {
  description = "Prefix used for dev GCP resource names."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,30}$", var.name_prefix))
    error_message = "name_prefix must start with a lowercase letter and contain only lowercase letters, numbers, and hyphens."
  }
}

variable "labels" {
  description = "Additional labels applied to supported GCP resources."
  type        = map(string)
  default     = {}
}

variable "dev_subnet_cidr" {
  description = "Primary CIDR range for the dev subnet."
  type        = string

  validation {
    condition     = can(cidrhost(var.dev_subnet_cidr, 0))
    error_message = "dev_subnet_cidr must be a valid CIDR in a.b.c.d/n form."
  }
}

variable "enable_private_google_access" {
  description = "Enable Private Google Access on the dev subnet."
  type        = bool
  default     = true
}

variable "db_database_version" {
  description = "Cloud SQL database version."
  type        = string
  default     = "POSTGRES_15"
}

variable "db_tier" {
  description = "Cloud SQL machine tier (dev 동시 연결 수요를 고려한 shared-core 기본값)."
  type        = string
  default     = "db-g1-small"
}

variable "db_name" {
  description = "Name of the dev application database."
  type        = string
  default     = "autoresearch"
}

variable "db_app_user" {
  description = "Application user for the dev database."
  type        = string
  default     = "app"
}

variable "sql_deletion_protection" {
  description = "Enable Cloud SQL instance deletion protection (GCP-side). dev는 false 권장."
  type        = bool
  default     = false
}

variable "private_services_cidr" {
  description = "CIDR for Cloud SQL Private Service Access (VPC peering). Must not overlap dev_subnet_cidr."
  type        = string

  validation {
    condition     = can(cidrhost(var.private_services_cidr, 0))
    error_message = "private_services_cidr must be a valid CIDR in a.b.c.d/n form."
  }
}

variable "redis_psc_subnet_cidr" {
  description = "Dedicated /29 subnet CIDR for Redis Cluster Private Service Connect endpoints."
  type        = string

  validation {
    condition     = can(cidrhost(var.redis_psc_subnet_cidr, 0)) && can(regex("/29$", var.redis_psc_subnet_cidr))
    error_message = "redis_psc_subnet_cidr must be a valid /29 CIDR."
  }
}

variable "redis_node_type" {
  description = "Memorystore for Redis Cluster node type. Shared-core nano is dev/test only and has no SLA."
  type        = string
  default     = "REDIS_SHARED_CORE_NANO"

  validation {
    condition = contains([
      "REDIS_SHARED_CORE_NANO",
      "REDIS_STANDARD_SMALL",
      "REDIS_HIGHMEM_MEDIUM",
      "REDIS_HIGHCPU_MEDIUM",
      "REDIS_STANDARD_LARGE",
      "REDIS_HIGHMEM_XLARGE",
      "REDIS_HIGHMEM_2XLARGE",
    ], var.redis_node_type)
    error_message = "redis_node_type must be a supported Memorystore for Redis Cluster node type."
  }
}

variable "redis_shard_count" {
  description = "Number of primary Redis Cluster shards. Issue #129 dev default is two data nodes."
  type        = number
  default     = 2

  validation {
    condition     = var.redis_shard_count >= 1 && var.redis_shard_count <= 250 && floor(var.redis_shard_count) == var.redis_shard_count
    error_message = "redis_shard_count must be an integer between 1 and 250."
  }
}

variable "redis_replica_count" {
  description = "Number of replica nodes per Redis Cluster shard. dev uses zero replicas and provides no HA."
  type        = number
  default     = 0

  validation {
    condition     = var.redis_replica_count >= 0 && var.redis_replica_count <= 5 && floor(var.redis_replica_count) == var.redis_replica_count
    error_message = "redis_replica_count must be an integer between 0 and 5."
  }
}

variable "redis_cluster_deletion_protection" {
  description = "Online Store Redis Cluster 삭제 보호. dev는 false이며 삭제 전 plan과 별도 승인이 필요."
  type        = bool
  default     = false
}

variable "gke_master_ipv4_cidr" {
  description = "Private GKE 컨트롤 플레인용 /28 CIDR. dev subnet/private services와 미중복."
  type        = string

  validation {
    condition     = can(cidrhost(var.gke_master_ipv4_cidr, 0))
    error_message = "gke_master_ipv4_cidr must be a valid CIDR in a.b.c.d/n form."
  }
}

variable "gke_pods_cidr" {
  description = "GKE pods용 서브넷 2차 대역. dev subnet/private services/master CIDR과 미중복."
  type        = string

  validation {
    condition     = can(cidrhost(var.gke_pods_cidr, 0))
    error_message = "gke_pods_cidr must be a valid CIDR in a.b.c.d/n form."
  }
}

variable "gke_services_cidr" {
  description = "GKE services용 서브넷 2차 대역. 다른 대역과 미중복."
  type        = string

  validation {
    condition     = can(cidrhost(var.gke_services_cidr, 0))
    error_message = "gke_services_cidr must be a valid CIDR in a.b.c.d/n form."
  }
}

variable "gke_machine_type" {
  description = "GKE 기본 dev node pool 머신 타입. Airflow/시스템 pod 여유와 live dev-default 기준은 4 vCPU / 16GB."
  type        = string
  default     = "e2-standard-4"
}

variable "gke_node_count_min" {
  description = "노드풀 autoscaling 최소 노드 수."
  type        = number
  default     = 1
}

variable "gke_node_count_max" {
  description = "노드풀 autoscaling 최대 노드 수."
  type        = number
  default     = 2
}

variable "gke_node_disk_size" {
  description = "노드 부트 디스크 크기(GB)."
  type        = number
  default     = 30
}

variable "gke_node_disk_type" {
  description = "노드 부트 디스크 타입."
  type        = string
  default     = "pd-standard"
}

variable "gke_release_channel" {
  description = "GKE release channel (관리형 업그레이드)."
  type        = string
  default     = "REGULAR"
}

variable "gke_deletion_protection" {
  description = "GKE cluster 삭제 보호. dev는 false 권장."
  type        = bool
  default     = false
}

variable "airflow_gke_node_pool_name" {
  description = "Airflow dev Helm release를 고정 배치할 GKE node pool 이름."
  type        = string
  default     = "airflow-dev"
}

variable "airflow_gke_machine_type" {
  description = "Airflow 전용 dev node pool 머신 타입."
  type        = string
  default     = "e2-standard-2"
}

variable "airflow_gke_node_count_min" {
  description = "Airflow 전용 node pool autoscaling 최소 노드 수."
  type        = number
  default     = 1
}

variable "airflow_gke_node_count_max" {
  description = "Airflow 전용 node pool autoscaling 최대 노드 수. #106: KPO 배치 피크의 escape valve(평시 1노드, 피크 시에만 확장 — KPO는 일회성이라 scale-down 점착성 없음)."
  type        = number
  default     = 2
}

variable "airflow_gke_node_disk_size" {
  description = "Airflow 전용 node pool 부트 디스크 크기(GB)."
  type        = number
  default     = 30
}

variable "airflow_gke_node_disk_type" {
  description = "Airflow 전용 node pool 부트 디스크 타입."
  type        = string
  default     = "pd-standard"
}

variable "master_authorized_networks" {
  description = "GKE 마스터 IP 엔드포인트 접근 허용 CIDR 목록(예비 경로). 기본 kubectl 경로는 DNS 엔드포인트(#45)라 IP 등록 불필요."
  type        = list(string)
  default     = []
}

variable "gke_app_k8s_namespace" {
  description = "Workload Identity로 매핑할 Kubernetes namespace."
  type        = string
  default     = "autoresearch"
}

variable "gke_app_k8s_service_account" {
  description = "Workload Identity로 매핑할 Kubernetes service account."
  type        = string
  default     = "autoresearch-app"
}

variable "experiment_runtime_k8s_namespace" {
  description = "Paired Feast experiment runtime GSA에 Workload Identity로 매핑할 Kubernetes namespace."
  type        = string
  default     = "experiment-runtime"

  validation {
    condition     = length(var.experiment_runtime_k8s_namespace) >= 1 && length(var.experiment_runtime_k8s_namespace) <= 63 && can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.experiment_runtime_k8s_namespace))
    error_message = "experiment_runtime_k8s_namespace must be a valid Kubernetes namespace name."
  }
}

variable "experiment_runtime_k8s_service_account" {
  description = "Paired Feast experiment runtime GSA에 Workload Identity로 매핑할 Kubernetes service account."
  type        = string
  default     = "experiment-runtime"

  validation {
    condition     = length(var.experiment_runtime_k8s_service_account) >= 1 && length(var.experiment_runtime_k8s_service_account) <= 63 && can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.experiment_runtime_k8s_service_account))
    error_message = "experiment_runtime_k8s_service_account must be a valid Kubernetes service account name."
  }
}

variable "agent_orchestration_db_name" {
  description = "Agent Orchestration 전용 Cloud SQL database 이름."
  type        = string
  default     = "agent_orchestration"
}

variable "agent_orchestration_db_user" {
  description = "Agent Orchestration 전용 Cloud SQL user 이름."
  type        = string
  default     = "agent_orchestration_app"
}

variable "agent_orchestration_runtime_database_role" {
  description = "Cloud SQL built-in runtime user에만 부여할 사전 생성 PostgreSQL custom role. 이 역할이 있어야 cloudsqlsuperuser 자동 부여를 피할 수 있다."
  type        = string
  default     = "agent_orchestration_runtime"

  validation {
    condition     = can(regex("^[a-z_][a-z0-9_]*$", var.agent_orchestration_runtime_database_role))
    error_message = "agent_orchestration_runtime_database_role must be a lowercase PostgreSQL role identifier."
  }
}

variable "agent_orchestration_k8s_namespace" {
  description = "Agent Orchestration API와 Runner KSA가 배치되는 Kubernetes namespace."
  type        = string
  default     = "autoresearch"
}

variable "agent_orchestration_api_k8s_service_account" {
  description = "Agent Orchestration API GSA에 Workload Identity로 매핑할 Kubernetes service account."
  type        = string
  default     = "agent-orchestration-api"
}

variable "agent_orchestration_runner_k8s_service_account" {
  description = "Agent Orchestration Codex Runner GSA에 Workload Identity로 매핑할 Kubernetes service account."
  type        = string
  default     = "agent-orchestration-runner"
}

variable "mlflow_db_name" {
  description = "기존 Cloud SQL 인스턴스 내 MLflow 전용 database 이름(Airflow/앱과 분리)."
  type        = string
  default     = "mlflow"
}

variable "mlflow_db_user" {
  description = "MLflow 전용 Cloud SQL user 이름."
  type        = string
  default     = "mlflow"
}

variable "mlflow_k8s_namespace" {
  description = "MLflow tracking server KSA가 배치될 Kubernetes namespace(#94 mlflow-k8s에서 생성)."
  type        = string
  default     = "mlflow"
}

variable "mlflow_k8s_service_account" {
  description = "MLflow GSA에 Workload Identity로 매핑할 Kubernetes service account."
  type        = string
  default     = "mlflow"
}

variable "experiment_job_k8s_namespace" {
  description = "Auto Research 실험 Job 전용 Kubernetes namespace. admin/autoresearch-k8s와 같은 값을 사용한다."
  type        = string
  default     = "autoresearch-experiments"

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.experiment_job_k8s_namespace))
    error_message = "experiment_job_k8s_namespace은 유효한 Kubernetes namespace 이름이어야 합니다."
  }
}

variable "experiment_job_k8s_service_account" {
  description = "결과 저장 Workload Identity에 매핑할 실험 Job Kubernetes service account."
  type        = string
  default     = "experiment-job"

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.experiment_job_k8s_service_account))
    error_message = "experiment_job_k8s_service_account는 유효한 Kubernetes service account 이름이어야 합니다."
  }
}

variable "experiment_results_bucket_location" {
  description = "실험 결과 전용 GCS 버킷 location."
  type        = string
  default     = "asia-northeast3"
}

variable "experiment_results_bucket_storage_class" {
  description = "실험 결과 전용 GCS 버킷 storage class."
  type        = string
  default     = "STANDARD"
}

variable "experiment_results_object_retention_days" {
  description = "실험 결과 live 객체 보존 일수. 결과 조회·감사와 비용 상한을 위해 1일 이상 정수만 허용한다."
  type        = number
  default     = 90

  validation {
    condition     = var.experiment_results_object_retention_days >= 1 && floor(var.experiment_results_object_retention_days) == var.experiment_results_object_retention_days
    error_message = "experiment_results_object_retention_days는 1 이상의 정수여야 합니다."
  }
}

variable "experiment_results_noncurrent_version_retention_days" {
  description = "실험 결과의 archived generation 보존 일수. live 삭제 후 운영자 복구 창을 제공한다."
  type        = number
  default     = 30

  validation {
    condition     = var.experiment_results_noncurrent_version_retention_days >= 1 && floor(var.experiment_results_noncurrent_version_retention_days) == var.experiment_results_noncurrent_version_retention_days
    error_message = "experiment_results_noncurrent_version_retention_days는 1 이상의 정수여야 합니다."
  }
}

variable "mlflow_bucket_location" {
  description = "MLflow artifact GCS bucket location."
  type        = string
  default     = "asia-northeast3"
}

variable "mlflow_bucket_storage_class" {
  description = "MLflow artifact GCS bucket storage class."
  type        = string
  default     = "STANDARD"
}

variable "mlflow_artifacts_soft_delete_seconds" {
  description = "MLflow artifact bucket soft delete 보존(초). 기본 7일 복구층(#179 교훈)."
  type        = number
  default     = 604800
}

variable "mlflow_training_snapshot_retention_days" {
  description = "training-snapshots/ live object age lifecycle 보존 일수. 0이면 자동 삭제하지 않는다."
  type        = number
  default     = 0

  validation {
    condition     = var.mlflow_training_snapshot_retention_days >= 0 && floor(var.mlflow_training_snapshot_retention_days) == var.mlflow_training_snapshot_retention_days
    error_message = "mlflow_training_snapshot_retention_days must be an integer greater than or equal to 0."
  }
}

variable "mlflow_artifact_noncurrent_retention_days" {
  description = "MLflow artifact bucket noncurrent generation 보존 일수. 0은 즉시 정리 위험 때문에 허용하지 않으며 기본 30일."
  type        = number
  default     = 30

  validation {
    condition     = var.mlflow_artifact_noncurrent_retention_days > 0 && floor(var.mlflow_artifact_noncurrent_retention_days) == var.mlflow_artifact_noncurrent_retention_days
    error_message = "mlflow_artifact_noncurrent_retention_days must be an integer greater than 0."
  }
}

variable "airflow_k8s_namespace" {
  description = "Airflow Helm release, Airflow KSA, batch KSA가 배치될 Kubernetes namespace."
  type        = string
  default     = "airflow"
}

variable "airflow_k8s_service_account" {
  description = "Airflow Workload Identity 매핑용 Kubernetes service account 이름."
  type        = string
  default     = "airflow"
}

variable "airflow_scheduler_k8s_service_account" {
  description = "Airflow Helm chart가 생성하는 스케줄러 KSA 이름. 스케줄러 파드에서 직접 실행되는 Google provider 오퍼레이터의 Workload Identity 매핑용."
  type        = string
  default     = "airflow-scheduler"
}

variable "airflow_batch_k8s_service_account" {
  description = "Airflow KubernetesPodOperator batch pod가 사용할 Kubernetes service account."
  type        = string
  default     = "autoresearch-batch"
}

variable "airflow_api_k8s_secret_name" {
  description = "YouTube/OpenRouter API key를 KPO pod에 주입하는 Kubernetes Secret 이름. Secret payload는 Terraform으로 관리하지 않는다."
  type        = string
  default     = "autoresearch-airflow-env"
}

variable "raw_data_bucket_location" {
  description = "원본 데이터 GCS bucket location. dev는 기본 region과 동일한 asia-northeast3."
  type        = string
  default     = "asia-northeast3"
}

variable "raw_data_bucket_storage_class" {
  description = "원본 데이터 GCS bucket storage class."
  type        = string
  default     = "STANDARD"
}

variable "raw_data_noncurrent_version_retention_days" {
  description = "GCS raw bucket noncurrent object version 보존 일수(dev 비용 방지)."
  type        = number
  default     = 30
}

# #522 raw 원자적 게시(copy+delete)가 delete 호출 전 크래시하면 IAM 권한과
# 무관하게 staging 임시 객체가 살아남는다. age 기반 삭제로 이 고아 경로를 자동
# 회수한다 — `_publish_staging/`는 임시 객체 전용 prefix라 age 기반 삭제가
# 안전하게 성립하는 몇 안 되는 경우다.
variable "raw_data_publish_staging_orphan_retention_days" {
  description = "GCS raw bucket _publish_staging/ prefix 아래 LIVE 객체를 정상 게시 소요 시간보다 넉넉히 지난 뒤 삭제하는 일수(#522 고아 staging 안전망)."
  type        = number
  default     = 1
}

variable "bigquery_location" {
  description = "dev BigQuery dataset location."
  type        = string
  default     = "asia-northeast3"
}

variable "bigquery_delete_contents_on_destroy" {
  description = "BigQuery dataset destroy 시 table/view contents 삭제 허용 여부. dev도 기본 false."
  type        = bool
  default     = false
}

variable "feast_bucket_location" {
  description = "Feast registry/staging GCS bucket location."
  type        = string
  default     = "asia-northeast3"
}

variable "feast_bucket_storage_class" {
  description = "Feast registry/staging GCS bucket storage class."
  type        = string
  default     = "STANDARD"
}

variable "feast_registry_noncurrent_version_retention_days" {
  description = "Feast registry bucket noncurrent object version 보존 일수(dev 비용 방지)."
  type        = number
  default     = 30
}

variable "feast_staging_object_retention_days" {
  description = "Feast staging bucket 임시 object 보존 일수(dev 비용 방지)."
  type        = number
  default     = 7
}

variable "proxy_image" {
  description = "proxy Cloud Run 컨테이너 이미지 전체 경로. 재배포 시 새 version tag 또는 digest로 변경한다. 비어 있으면 dev AR 리포의 proxy:dev-20260708-001 예시 태그를 사용."
  type        = string
  default     = ""

  validation {
    condition     = var.proxy_image == "" || can(regex("@sha256:[0-9a-f]{64}$", var.proxy_image)) || !can(regex(":latest$", var.proxy_image))
    error_message = "proxy_image must use a versioned tag or digest. Mutable :latest is not allowed because Terraform cannot detect a new image pushed to the same tag."
  }
}

variable "proxy_ingress" {
  description = "proxy Cloud Run ingress 정책. collector가 VPC 밖에서 호출하면 INGRESS_TRAFFIC_ALL로 변경(IAM 인증은 유지)."
  type        = string
  default     = "INGRESS_TRAFFIC_INTERNAL_ONLY"

  validation {
    condition = contains([
      "INGRESS_TRAFFIC_ALL",
      "INGRESS_TRAFFIC_INTERNAL_ONLY",
      "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER",
    ], var.proxy_ingress)
    error_message = "proxy_ingress must be a valid Cloud Run v2 ingress value."
  }
}

variable "proxy_max_instances" {
  description = "proxy Cloud Run 최대 인스턴스 수. dev 트래픽(일 수 회)에는 1이면 충분."
  type        = number
  default     = 1
}

variable "proxy_cpu" {
  description = "proxy 컨테이너 vCPU limit (dev 최소 비용)."
  type        = string
  default     = "1"
}

variable "proxy_memory" {
  description = "proxy 컨테이너 메모리 limit (dev 최소 비용)."
  type        = string
  default     = "512Mi"
}

variable "proxy_invoker_members" {
  description = "Airflow batch 외에 proxy 호출(run.invoker)을 추가 허용할 IAM member 목록 (예: serviceAccount:collector@...)."
  type        = list(string)
  default     = []
}

variable "proxy_deletion_protection" {
  description = "proxy Cloud Run 서비스 삭제 보호. dev는 false 권장."
  type        = bool
  default     = false
}

variable "bastion_enabled" {
  description = "IAP 터널 전용 bastion VM 생성 여부. 장기 미사용 시 false로 비용 절감."
  type        = bool
  default     = true
}

variable "bastion_machine_type" {
  description = "bastion VM 머신 타입 (dev 최소 비용, 터널 종단 용도)."
  type        = string
  default     = "e2-micro"
}

variable "bastion_disk_size_gb" {
  description = "bastion 부트 디스크 크기(GB)."
  type        = number
  default     = 10
}

variable "bastion_image" {
  description = "bastion 부트 디스크 이미지."
  type        = string
  default     = "debian-cloud/debian-12"
}

variable "internal_dns_domain" {
  description = "VPC 내부 전용 private DNS 도메인 (trailing dot 없이). Airflow UI는 airflow.<domain>."
  type        = string
  default     = "dev.autoresearch.internal"

  validation {
    condition     = can(regex("^[a-z0-9.-]+[a-z]$", var.internal_dns_domain))
    error_message = "internal_dns_domain must be a bare domain without trailing dot."
  }
}

variable "elastic_k8s_namespace" {
  description = "Elasticsearch Workload Identity 매핑용 Kubernetes namespace(#102). 실제 namespace는 terraform/admin/elastic-k8s가 관리."
  type        = string
  default     = "elastic"
}

variable "es_k8s_service_account" {
  description = "Elasticsearch pod의 Workload Identity 매핑용 Kubernetes service account 이름(#102)."
  type        = string
  default     = "elasticsearch"
}

variable "actions_runner_namespace" {
  description = "셀프 호스티드 러너(ARC) Workload Identity 매핑용 Kubernetes namespace(#533). 실제 namespace는 terraform/admin/actions-runner-k8s가 관리."
  type        = string
  default     = "actions-runner"
}

variable "actions_runner_controller_ksa" {
  description = "ARC 컨트롤러 매니저 Pod의 Workload Identity 매핑용 Kubernetes service account 이름(#533)."
  type        = string
  default     = "actions-runner-controller"
}

variable "batch_spot_gke_node_pool_name" {
  description = "KPO batch 전용 Spot node pool 이름(#173)."
  type        = string
  default     = "batch-spot"
}

variable "batch_spot_gke_machine_type" {
  description = "batch Spot pool 머신 타입(#173). #422에서 n2로 전환 — 새 프로젝트는 PREEMPTIBLE quota 0이라 Spot도 E2_CPUS(한도 24)를 소모해 8노드 버스트가 한도 초과. N2_CPUS(한도 200)로 수요를 이전한다."
  type        = string
  default     = "n2-standard-2"
}

variable "batch_spot_gke_node_count_max" {
  description = "batch Spot pool autoscaling 최대 노드 수(#173, #330에서 2→8 상향). min은 0 고정(평시 비용 0)이라 상한 확대는 유휴 비용 증가 없음 — 병렬 배치(action-log 샤딩·backfill) 동시성 확보."
  type        = number
  default     = 8
}

variable "batch_od_gke_node_pool_name" {
  description = "재시도 내성이 없는 장시간 KPO용 비-Spot(on-demand) node pool 이름(#297)."
  type        = string
  default     = "batch-od"
}

variable "batch_od_gke_machine_type" {
  description = "batch on-demand pool 머신 타입(#297). batch-spot과 동일 사양."
  type        = string
  default     = "e2-standard-2"
}

variable "ctr_retrain_gke_node_count_max" {
  description = "CTR 재학습 노드풀 autoscaling 최대 노드 수(#316, #330에서 1→2 상향). min은 0 고정(평시 비용 0) — 병렬 재학습/HPO 대비."
  type        = number
  default     = 2
}

variable "batch_od_gke_node_count_max" {
  description = "batch on-demand pool autoscaling 최대 노드 수(#297). min은 0 고정(평시 비용 0)."
  type        = number
  default     = 2
}

variable "airflow_deploy_ref" {
  description = "Autoresearch-airflow의 GAR push와 GKE deploy workflow에 허용하는 정확한 ref. WIF principalSet을 이 ref로 제한해 임의 브랜치의 SA 가장을 막는다."
  type        = string
  default     = "refs/heads/main"
}

# #451 단일 진입점. apply SA 2종(dev-apply·admin-apply) 모두 이 workflow_ref
# 하나만 가장할 수 있다. 옛 admin_apply_workflow_ref·dev_apply_workflow_ref
# 변수(admin-apply.yml/dev-apply.yml 전용)는 3단계에서 이 변수로 교체돼
# 제거됐다 — 이관 순서(1단계 바인딩 추가 → 2단계 workflow 교체 → 3단계 옛
# 바인딩·변수 제거)는 docs/CHANGE_HISTORY.md 2026-07-31 항목 참고.
variable "apply_workflow_ref" {
  description = "#451 통합 apply.yml workflow_ref. dev root와 admin root apply SA를 모두 이 workflow가 가장한다(진입점 단일화 — 통제는 SA 분리 + Environment 승인 게이트)."
  type        = string
  default     = "SKYAHO/Autoresearch-infra/.github/workflows/apply.yml@refs/heads/main"
}

variable "application_release_workflow_ref" {
  description = "애플리케이션 GAR push SA를 가장할 수 있는 정확한 Autoresearch release workflow_ref. workflow_dispatch는 main source ref로 제한한다."
  type        = string
  default     = "SKYAHO/Autoresearch/.github/workflows/release.yml@refs/heads/main"
}

variable "code_uploader_workflow_ref" {
  description = "코드 아카이브 업로더 SA를 가장할 수 있는 정확한 Autoresearch code-archive workflow_ref (#238). push(main)·workflow_dispatch(main) 모두 이 ref다."
  type        = string
  default     = "SKYAHO/Autoresearch/.github/workflows/code-archive.yml@refs/heads/main"
}

variable "application_release_workflow_event_path" {
  description = "애플리케이션 GAR push SA를 가장할 수 있는 tag 기반 release 이벤트의 정확한 Autoresearch release 워크플로우 경로. event_name과 workflow path를 함께 검증한다."
  type        = string
  default     = "release:SKYAHO/Autoresearch/.github/workflows/release.yml"
}

variable "feast_apply_workflow_ref" {
  description = "feast apply SA를 가장할 수 있는 정확한 Autoresearch feast-apply workflow_ref (#332). push(main)·workflow_dispatch(main) 모두 이 ref다."
  type        = string
  default     = "SKYAHO/Autoresearch/.github/workflows/feast-apply.yml@refs/heads/main"
}

variable "rerank_loadtest_workflow_ref" {
  description = "정확한 Autoresearch rerank serving 부하테스트 workflow만 두 전용 GSA를 가장할 수 있는 workflow_ref (#482)."
  type        = string
  default     = "SKYAHO/Autoresearch/.github/workflows/rerank-loadtest.yml@refs/heads/main"

  validation {
    condition     = can(regex("^SKYAHO/Autoresearch/\\.github/workflows/rerank-loadtest\\.yml@refs/heads/main$", var.rerank_loadtest_workflow_ref))
    error_message = "rerank_loadtest_workflow_ref must point to the main-branch rerank-loadtest.yml workflow."
  }
}

# #424 Feast apply GKE Job의 Workload Identity subject는 환경별로 고정한다.
# 실제 namespace/KSA 오브젝트와 GSA annotation은
# terraform/admin/autoresearch-k8s가 같은 dev/prod 계약으로 생성한다.
variable "feast_apply_kubernetes_identities" {
  description = "Feast apply 환경별 Kubernetes namespace/KSA 계약. Task 2의 Workload Identity subject(feast-apply-dev|prod/feast-apply)와 정확히 같아야 한다."
  type = map(object({
    namespace       = string
    service_account = string
  }))
  default = {
    dev = {
      namespace       = "feast-apply-dev"
      service_account = "feast-apply"
    }
    prod = {
      namespace       = "feast-apply-prod"
      service_account = "feast-apply"
    }
  }

  validation {
    condition = (
      length(var.feast_apply_kubernetes_identities) == 2 &&
      alltrue([for environment in keys(var.feast_apply_kubernetes_identities) : contains(["dev", "prod"], environment)]) &&
      alltrue([
        for identity in values(var.feast_apply_kubernetes_identities) :
        length(identity.namespace) >= 1 &&
        length(identity.namespace) <= 63 &&
        can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", identity.namespace)) &&
        length(identity.service_account) >= 1 &&
        length(identity.service_account) <= 63 &&
        can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", identity.service_account))
      ])
    )
    error_message = "feast_apply_kubernetes_identities must contain exactly dev and prod with valid Kubernetes namespace and service account names."
  }
}
