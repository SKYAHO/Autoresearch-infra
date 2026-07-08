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

variable "private_services_cidr" {
  description = "Private services CIDR that contains the Cloud SQL private IP range."
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

variable "ui_ingress_source_cidr" {
  description = "Airflow webserver(8080)로 ingress를 허용할 VPC 내부 CIDR (#48). dev subnet 기본."
  type        = string
  default     = "10.10.0.0/20"

  validation {
    condition     = can(cidrhost(var.ui_ingress_source_cidr, 0))
    error_message = "ui_ingress_source_cidr must be a valid CIDR in a.b.c.d/n form."
  }
}
