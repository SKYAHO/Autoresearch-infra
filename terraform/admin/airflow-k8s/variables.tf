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

variable "airflow_k8s_namespace" {
  description = "Kubernetes namespace for Airflow."
  type        = string
  default     = "airflow"
}

variable "airflow_k8s_service_account" {
  description = "Kubernetes service account annotated for Workload Identity."
  type        = string
  default     = "airflow"
}

variable "airflow_gcp_service_account_email" {
  description = "Airflow GCP service account email from terraform/envs/dev output. Empty value derives the dev default name."
  type        = string
  default     = ""
}

variable "airflow_deployer_service_account_email" {
  description = "GitHub Actions Airflow deployer GSA email from terraform/envs/dev output. Empty value derives the dev default name."
  type        = string
  default     = ""
}

variable "private_services_cidr" {
  description = "Cloud SQL private IP가 속한 PSA 대역(autoresearch-dev-private-sql-range). dev root·mlflow-k8s와 반드시 일치해야 하며, 불일치 시 egress NetworkPolicy가 5432를 차단해 Airflow가 DB에 접속하지 못한다(#253). default는 현재 PSA 대역."
  type        = string

  validation {
    condition     = can(cidrhost(var.private_services_cidr, 0))
    error_message = "private_services_cidr must be a valid CIDR in a.b.c.d/n form."
  }
}

variable "installer_user_emails" {
  description = "Google accounts granted namespace-scoped admin for Helm install. Keep real values in local terraform.tfvars only."
  type        = set(string)
  default     = []

  validation {
    condition = alltrue([
      for e in var.installer_user_emails :
      can(regex("^[^@]+@[^@]+\\.[^@]+$", e)) && !strcontains(e, ":")
    ])
    error_message = "Each item must be an email without a user: prefix."
  }
}

variable "cluster_services_cidr" {
  description = "GKE services 2차 대역 (#122). service VIP 경유 egress(DNS/in-cluster PostgreSQL)를 ipBlock으로 허용하는 데 사용. dev root의 gke_services_cidr와 일치해야 한다."
  type        = string

  validation {
    condition     = can(cidrhost(var.cluster_services_cidr, 0))
    error_message = "cluster_services_cidr must be a valid CIDR in a.b.c.d/n form."
  }
}

variable "redis_psc_subnet_cidr" {
  description = "Redis Cluster PSC subnet CIDR from terraform/envs/dev redis_psc_subnet_cidr output."
  type        = string

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
    condition     = var.redis_node_port_end >= 1 && var.redis_node_port_end <= 65535 && floor(var.redis_node_port_end) == var.redis_node_port_end && var.redis_node_port_end >= var.redis_node_port_start
    error_message = "redis_node_port_end must be an integer between 1 and 65535 and not lower than redis_node_port_start."
  }
}

variable "ui_ingress_source_cidr" {
  description = "Airflow webserver(8080)로 ingress를 허용할 VPC 내부 CIDR (#48). dev subnet 기본."
  type        = string
  default     = "10.10.0.0/20"

  validation {
    condition     = can(cidrhost(var.ui_ingress_source_cidr, 0))
    error_message = "ui_ingress_source_cidr must be a valid CIDR in a.b.c.d/n form."
  }
}

variable "airflow_batch_k8s_service_account" {
  description = "KPO 배치 파드용 KSA 이름(#427). terraform/envs/dev의 airflow_batch_k8s_service_account와 같은 값이어야 한다 — dev root가 이 이름으로 WI principal을 조립해 GSA 가장을 허용하므로, 불일치 시 어느 plan에서도 잡히지 않고 KPO 파드 런타임의 GCP 호출(토큰 교환)만 403으로 실패한다(#427의 admission 403과 구분됨)."
  type        = string
  default     = "autoresearch-batch"

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.airflow_batch_k8s_service_account))
    error_message = "airflow_batch_k8s_service_account must be a valid lowercase RFC 1123 name."
  }
}

variable "airflow_batch_gcp_service_account_email" {
  description = "배치 KSA에 연결할 GSA email. 비우면 resource_prefix/project_id로 파생하며, terraform/envs/dev가 만드는 airflow_batch GSA와 일치해야 한다. 불일치 시 plan은 통과하고 KPO 파드 런타임에서 토큰 교환이 403으로 실패한다."
  type        = string
  default     = ""

  validation {
    condition     = var.airflow_batch_gcp_service_account_email == "" || can(regex("^[^@]+@[^@]+\\.iam\\.gserviceaccount\\.com$", var.airflow_batch_gcp_service_account_email))
    error_message = "airflow_batch_gcp_service_account_email must be empty or a GSA email in <id>@<project>.iam.gserviceaccount.com form."
  }
}
