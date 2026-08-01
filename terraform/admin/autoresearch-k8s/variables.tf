variable "project_id" {
  description = "GCP project id that hosts the dev GKE cluster."
  type        = string
}

variable "region" {
  description = "Default GCP region."
  type        = string
  default     = "asia-northeast3"
}

variable "zone" {
  description = "GKE cluster zone."
  type        = string
  default     = "asia-northeast3-a"
}

variable "gke_cluster_name" {
  description = "Existing dev GKE cluster name."
  type        = string
  default     = "autoresearch-dev-gke"
}

variable "resource_prefix" {
  description = "Resource prefix used by terraform/envs/dev."
  type        = string
  default     = "autoresearch-dev"
}

variable "app_k8s_namespace" {
  description = "Kubernetes namespace for Autoresearch application workloads."
  type        = string
  default     = "autoresearch"

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.app_k8s_namespace))
    error_message = "app_k8s_namespace must be a valid Kubernetes namespace name."
  }
}

variable "app_k8s_service_account" {
  description = "Kubernetes service account mapped to the app GCP service account."
  type        = string
  default     = "autoresearch-app"

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.app_k8s_service_account))
    error_message = "app_k8s_service_account must be a valid Kubernetes service account name."
  }
}

variable "app_gcp_service_account_email" {
  description = "App GCP service account email from terraform/envs/dev output. Empty value derives the dev default name."
  type        = string
  default     = ""
}

variable "agent_orchestration_api_k8s_service_account" {
  description = "Agent Orchestration API의 전용 Kubernetes service account 이름."
  type        = string
  default     = "agent-orchestration-api"
}

variable "agent_orchestration_runner_k8s_service_account" {
  description = "Agent Orchestration Codex Runner의 전용 Kubernetes service account 이름."
  type        = string
  default     = "agent-orchestration-runner"
}

variable "agent_orchestration_api_gcp_service_account_email" {
  description = "Agent Orchestration API GSA email. 빈 값이면 resource_prefix/project_id에서 dev 기본값을 파생한다."
  type        = string
  default     = ""
}

variable "agent_orchestration_runner_gcp_service_account_email" {
  description = "Agent Orchestration Codex Runner GSA email. 빈 값이면 resource_prefix/project_id에서 dev 기본값을 파생한다."
  type        = string
  default     = ""
}

# #424 환경 이름은 GitHub Environment → WIF provider → GSA → namespace → KSA
# 신뢰 경계 전체의 키다. null 기본값은 resource_prefix/project_id에서 안전한 기본값을
# 파생하며, map override는 두 환경의 완전한 튜플만 허용한다.
variable "feast_apply_identities" {
  description = "Feast apply 환경별 GSA/namespace/KSA 계약. terraform/envs/dev의 feast_apply_kubernetes_identities 및 Task 2의 WI subject와 정확히 같아야 한다."
  type = map(object({
    namespace                 = string
    service_account           = string
    gcp_service_account_email = string
  }))
  default  = null
  nullable = true

  validation {
    condition = (
      var.feast_apply_identities == null ||
      (
        length(var.feast_apply_identities) == 2 &&
        alltrue([for environment in keys(var.feast_apply_identities) : contains(["dev", "prod"], environment)]) &&
        alltrue([
          for identity in values(var.feast_apply_identities) :
          length(identity.namespace) >= 1 &&
          length(identity.namespace) <= 63 &&
          can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", identity.namespace)) &&
          length(identity.service_account) >= 1 &&
          length(identity.service_account) <= 63 &&
          can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", identity.service_account)) &&
          trimspace(identity.gcp_service_account_email) != "" &&
          can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.iam\\.gserviceaccount\\.com$", identity.gcp_service_account_email))
        ])
      )
    )
    error_message = "feast_apply_identities override must contain exactly dev and prod with valid Kubernetes identifiers and non-empty GSA emails."
  }
}

variable "private_services_cidr" {
  description = "Private Service Access CIDR containing the Cloud SQL private endpoint."
  type        = string

  validation {
    condition     = can(cidrhost(var.private_services_cidr, 0))
    error_message = "private_services_cidr must be a valid CIDR in a.b.c.d/n form."
  }
}

variable "cluster_services_cidr" {
  description = "GKE services secondary CIDR used to allow service VIP traffic such as kube-dns."
  type        = string
  default     = "172.16.128.0/24"

  validation {
    condition     = can(cidrhost(var.cluster_services_cidr, 0))
    error_message = "cluster_services_cidr must be a valid CIDR in a.b.c.d/n form."
  }
}

variable "redis_psc_subnet_cidr" {
  description = "Redis Cluster PSC subnet CIDR from terraform/envs/dev redis_psc_subnet_cidr output."
  type        = string
  default     = "10.10.16.0/29"

  validation {
    condition     = can(cidrhost(var.redis_psc_subnet_cidr, 0)) && can(regex("/29$", var.redis_psc_subnet_cidr))
    error_message = "redis_psc_subnet_cidr must be a valid /29 CIDR."
  }
}

variable "redis_discovery_port" {
  description = "Memorystore for Redis Cluster discovery endpoint port."
  type        = number
  default     = 6379

  validation {
    condition     = var.redis_discovery_port >= 1 && var.redis_discovery_port <= 65535 && floor(var.redis_discovery_port) == var.redis_discovery_port
    error_message = "redis_discovery_port must be an integer between 1 and 65535."
  }
}

variable "redis_node_port_start" {
  description = "First Redis Cluster data node port returned by cluster topology."
  type        = number
  default     = 11000

  validation {
    condition     = var.redis_node_port_start >= 1 && var.redis_node_port_start <= 65535 && floor(var.redis_node_port_start) == var.redis_node_port_start
    error_message = "redis_node_port_start must be an integer between 1 and 65535."
  }
}

variable "redis_node_port_end" {
  description = "Last Redis Cluster data node port returned by cluster topology."
  type        = number
  default     = 13047

  validation {
    condition     = var.redis_node_port_end >= 1 && var.redis_node_port_end <= 65535 && floor(var.redis_node_port_end) == var.redis_node_port_end
    error_message = "redis_node_port_end must be an integer between 1 and 65535."
  }
}

variable "autoresearch_viewer_user_emails" {
  description = "Google accounts granted namespace-scoped read (view) plus pods/portforward on the autoresearch namespace, for app/model pod debugging. Keep real values in local terraform.tfvars only."
  type        = set(string)
  default     = []

  validation {
    condition = alltrue([
      for e in var.autoresearch_viewer_user_emails :
      can(regex("^[^@]+@[^@]+\\.[^@]+$", e)) && !strcontains(e, ":")
    ])
    error_message = "Each item must be an email without a user: prefix."
  }
}

variable "loadtest_namespace" {
  description = "Kubernetes namespace dedicated to the rerank serving load test."
  type        = string
  default     = "loadtest"

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.loadtest_namespace))
    error_message = "loadtest_namespace must be a valid Kubernetes namespace name."
  }
}

variable "rerank_loadtest_service_account" {
  description = "Kubernetes service account used by the k6 Job."
  type        = string
  default     = "rerank-loadtest"

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.rerank_loadtest_service_account))
    error_message = "rerank_loadtest_service_account must be a valid Kubernetes service account name."
  }
}

variable "rerank_loadtest_runner_github_gsa_email" {
  description = "GSA email used by the GitHub Actions runner and bound to the loadtest namespace Role. Empty derives the dev default."
  type        = string
  default     = ""

  validation {
    condition = (
      trimspace(var.rerank_loadtest_runner_github_gsa_email) == "" ||
      can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.iam\\.gserviceaccount\\.com$", var.rerank_loadtest_runner_github_gsa_email))
    )
    error_message = "rerank_loadtest_runner_github_gsa_email must be a GSA email when set."
  }
}

variable "rerank_loadtest_snapshot_reader_github_gsa_email" {
  description = "GSA email used by the GitHub Actions Prometheus snapshot reader and bound to the monitoring Service proxy Role. Empty derives the dev default."
  type        = string
  default     = ""

  validation {
    condition = (
      trimspace(var.rerank_loadtest_snapshot_reader_github_gsa_email) == "" ||
      can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.iam\\.gserviceaccount\\.com$", var.rerank_loadtest_snapshot_reader_github_gsa_email))
    )
    error_message = "rerank_loadtest_snapshot_reader_github_gsa_email must be a GSA email when set."
  }
}

variable "experiment_job_namespace" {
  description = "Auto Research 실험 Job을 기존 앱 namespace와 분리해 실행할 Kubernetes namespace."
  type        = string
  default     = "autoresearch-experiments"

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.experiment_job_namespace))
    error_message = "experiment_job_namespace은 유효한 Kubernetes namespace 이름이어야 합니다."
  }
}

variable "experiment_job_k8s_service_account" {
  description = "결과 GCS 버킷 Workload Identity에 연결할 실험 Job Kubernetes service account."
  type        = string
  default     = "experiment-job"

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.experiment_job_k8s_service_account))
    error_message = "experiment_job_k8s_service_account는 유효한 Kubernetes service account 이름이어야 합니다."
  }
}

variable "experiment_job_gcp_service_account_email" {
  description = "실험 Job GSA email. 빈 값이면 resource_prefix/project_id에서 기본값을 파생한다."
  type        = string
  default     = ""

  validation {
    condition = (
      trimspace(var.experiment_job_gcp_service_account_email) == "" ||
      can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.iam\\.gserviceaccount\\.com$", var.experiment_job_gcp_service_account_email))
    )
    error_message = "experiment_job_gcp_service_account_email은 설정 시 유효한 GSA email이어야 합니다."
  }
}

variable "enable_experiment_job_creation" {
  description = "Agent Orchestration API의 실험 Job 생성 권한 활성화 여부. 고정 템플릿·허용 digest·admission 검증 완료 전에는 false를 유지한다."
  type        = bool
  default     = false
}

variable "private_googleapis_cidr" {
  description = "Private Google Access DNS가 해석하는 Google API VIP CIDR."
  type        = string
  default     = "199.36.153.8/30"

  validation {
    condition     = can(cidrhost(var.private_googleapis_cidr, 0))
    error_message = "private_googleapis_cidr은 유효한 CIDR이어야 합니다."
  }
}
