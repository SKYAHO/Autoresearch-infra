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
