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
  default     = "192.168.0.0/20"

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
