variable "project_id" {
  description = "GCP project id that hosts the dev GKE cluster."
  type        = string
}

variable "region" {
  description = "Default GCP region."
  type        = string
}

variable "zone" {
  description = "GKE cluster zone."
  type        = string
}

variable "gke_cluster_name" {
  description = "Existing dev GKE cluster name."
  type        = string
}

variable "resource_prefix" {
  description = "Resource prefix used by terraform/envs/dev."
  type        = string
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

variable "experiment_runtime_k8s_namespace" {
  description = "Kubernetes namespace dedicated to paired Feast experiment runtime Jobs."
  type        = string
  default     = "experiment-runtime"

  validation {
    condition     = length(var.experiment_runtime_k8s_namespace) >= 1 && length(var.experiment_runtime_k8s_namespace) <= 63 && can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.experiment_runtime_k8s_namespace))
    error_message = "experiment_runtime_k8s_namespace must be a valid Kubernetes namespace name."
  }
}

variable "experiment_runtime_k8s_service_account" {
  description = "Kubernetes service account mapped to the experiment runtime GCP service account."
  type        = string
  default     = "experiment-runtime"

  validation {
    condition     = length(var.experiment_runtime_k8s_service_account) >= 1 && length(var.experiment_runtime_k8s_service_account) <= 63 && can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.experiment_runtime_k8s_service_account))
    error_message = "experiment_runtime_k8s_service_account must be a valid Kubernetes service account name."
  }
}

variable "experiment_runtime_gcp_service_account_email" {
  description = "Experiment runtime GSA email from terraform/envs/dev output. Empty derives the dev default."
  type        = string
  default     = ""

  validation {
    condition = (
      var.experiment_runtime_gcp_service_account_email == "" ||
      can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]@[a-z][a-z0-9-]{4,28}[a-z0-9]\\.iam\\.gserviceaccount\\.com$", var.experiment_runtime_gcp_service_account_email))
    )
    error_message = "experiment_runtime_gcp_service_account_email must be empty or use 6-30 character lowercase account/project IDs that start with a letter, contain only letters, digits, or hyphens, and end with a letter or digit."
  }
}

variable "airflow_k8s_namespace" {
  description = "Airflow namespace whose in-cluster service account observes experiment runtime Jobs. Must match terraform/envs/dev."
  type        = string
  default     = "airflow"

  validation {
    condition     = length(var.airflow_k8s_namespace) >= 1 && length(var.airflow_k8s_namespace) <= 63 && can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.airflow_k8s_namespace))
    error_message = "airflow_k8s_namespace must be a valid Kubernetes namespace name."
  }
}

variable "airflow_k8s_service_account" {
  description = "Airflow in-cluster service account bound to the experiment runtime observer Role. Must match terraform/envs/dev."
  type        = string
  default     = "airflow"

  validation {
    condition     = length(var.airflow_k8s_service_account) >= 1 && length(var.airflow_k8s_service_account) <= 63 && can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.airflow_k8s_service_account))
    error_message = "airflow_k8s_service_account must be a valid Kubernetes service account name."
  }
}

variable "private_googleapis_cidr" {
  description = "Private Google APIs VIP CIDR allowed from experiment runtime Jobs."
  type        = string
  default     = "199.36.153.8/30"

  validation {
    condition     = can(cidrhost(var.private_googleapis_cidr, 0)) && var.private_googleapis_cidr == "199.36.153.8/30"
    error_message = "private_googleapis_cidr must be the canonical Private Google APIs CIDR 199.36.153.8/30."
  }
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

# #539 이 값은 terraform/envs/dev의 agent_orchestration_launcher_k8s_service_account와
# 반드시 같아야 한다 — 불일치는 두 root의 apply를 모두 통과한 뒤 Workload Identity
# principal이 어긋나 launcher Pod의 Secret Manager 접근 403으로만 드러난다.
variable "agent_orchestration_launcher_k8s_service_account" {
  description = "실험 브랜치 Job launcher의 전용 Kubernetes service account 이름."
  type        = string
  default     = "agent-orchestration-launcher"

  validation {
    condition     = length(var.agent_orchestration_launcher_k8s_service_account) >= 1 && length(var.agent_orchestration_launcher_k8s_service_account) <= 63 && can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.agent_orchestration_launcher_k8s_service_account))
    error_message = "agent_orchestration_launcher_k8s_service_account must be a valid Kubernetes service account name."
  }
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

variable "agent_orchestration_launcher_gcp_service_account_email" {
  description = "실험 브랜치 Job launcher GSA email. 빈 값이면 resource_prefix/project_id에서 dev 기본값을 파생한다."
  type        = string
  default     = ""

  validation {
    condition = (
      trimspace(var.agent_orchestration_launcher_gcp_service_account_email) == "" ||
      can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.iam\\.gserviceaccount\\.com$", var.agent_orchestration_launcher_gcp_service_account_email))
    )
    error_message = "agent_orchestration_launcher_gcp_service_account_email must be a GSA email when set."
  }
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
  description = "Auto Research 실험 Job을 기존 앱 namespace와 분리해 실행할 Kubernetes namespace. terraform/envs/dev의 experiment_job_k8s_namespace와 반드시 같은 값이어야 한다 — 불일치는 두 root의 plan/apply를 모두 통과한 뒤 Workload Identity principal(svc.id.goog[ns/ksa])이 어긋나 Job의 GCS 업로드 403으로만 드러난다."
  type        = string
  default     = "autoresearch-experiments"

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.experiment_job_namespace))
    error_message = "experiment_job_namespace은 유효한 Kubernetes namespace 이름이어야 합니다."
  }
}

variable "experiment_job_node_pool" {
  description = "실험 Job을 고정할 GKE node pool 이름. terraform/envs/dev의 batch_od_gke_node_pool_name과 반드시 같은 값이어야 한다 — 불일치는 두 root의 plan/apply를 모두 통과한 뒤, admission이 실제 pool과 다른 이름을 요구해 모든 Job이 거부되는 형태로만 드러난다."
  type        = string
  default     = "batch-od"

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.experiment_job_node_pool))
    error_message = "experiment_job_node_pool은 유효한 GKE node pool 이름이어야 합니다."
  }
}

# digest 고정만으로는 이미지의 "불변성"만 보장되고 "출처"는 보장되지 않는다.
# 이미지 pull은 kubelet이 노드에서 수행하므로 namespace egress NetworkPolicy가
# 적용되지 않고, batch-od 노드는 Cloud NAT로 외부 registry에 도달할 수 있다.
# 따라서 허용 registry/repository prefix를 함께 강제해야 "허용된 이미지인가"까지
# 계약대로 막힌다.
variable "experiment_job_allowed_image_prefixes" {
  description = "실험 Job 컨테이너 이미지에 허용할 registry/repository prefix 목록. 기본값은 이 프로젝트의 Artifact Registry Docker 저장소다."
  type        = list(string)
  default     = null

  validation {
    condition     = var.experiment_job_allowed_image_prefixes == null || length(coalesce(var.experiment_job_allowed_image_prefixes, [])) > 0
    error_message = "experiment_job_allowed_image_prefixes를 지정하면 최소 한 개의 prefix가 필요합니다(빈 목록은 모든 이미지를 거부해 Job이 전부 실패한다)."
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

# #539에서 이 플래그의 주체가 API KSA에서 launcher KSA로 바뀌었다. 변수 이름은
# 주체를 담고 있지 않아 그대로 두되(로컬 tfvars·runbook·CHANGE_HISTORY의 참조가
# 깨지지 않는다), 아래 설명과 outputs의 필드 이름으로 새 주체를 드러낸다.
# #539 branch-writer GitHub App private key를 담는 Kubernetes Secret 이름. 값(PEM)은
# Terraform이 관리하지 않고 runbook의 수동 주입 절차로만 넣는다. 이 변수는 admission이
# "이 Secret 하나만 마운트할 수 있다"를 강제하는 데 쓰인다 — 이름을 고정하지 않으면
# 손상된 제출자가 더 강한 권한의 다른 App 키 Secret을 같은 위치에 마운트할 수 있다.
variable "experiment_branch_writer_secret_name" {
  description = "branch-bootstrap Job이 마운트할 수 있는 유일한 GitHub App private key Kubernetes Secret 이름. 값은 Terraform이 관리하지 않는다."
  type        = string
  default     = "autoresearch-experiment-branch-writer-app"

  validation {
    condition     = length(var.experiment_branch_writer_secret_name) >= 1 && length(var.experiment_branch_writer_secret_name) <= 253 && can(regex("^[a-z0-9]([-.a-z0-9]*[a-z0-9])?$", var.experiment_branch_writer_secret_name))
    error_message = "experiment_branch_writer_secret_name must be a valid Kubernetes Secret name."
  }
}

variable "enable_experiment_job_creation" {
  description = "실험 브랜치 launcher KSA의 Job 생성 권한 활성화 여부. #523 선행 조건(고정 템플릿·허용 digest·admission 검증, NetworkPolicy sync 재확인, negative dry-run 4종 재실행 — 이슈 댓글 기록 완료) 충족 후 true로 전환했고, #539에서 주체만 API KSA → launcher KSA로 옮겼다. 문제 발생 시 false로 되돌리는 것이 CronJob 중지 다음의 롤백 수단이다."
  type        = bool
  default     = true
}
