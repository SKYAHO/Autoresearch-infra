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

variable "mlflow_k8s_namespace" {
  description = "Kubernetes namespace for the MLflow tracking server."
  type        = string
  default     = "mlflow"

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.mlflow_k8s_namespace))
    error_message = "mlflow_k8s_namespace must be a valid Kubernetes namespace name."
  }
}

variable "mlflow_k8s_service_account" {
  description = "Kubernetes service account mapped to the MLflow GCP service account."
  type        = string
  default     = "mlflow"

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.mlflow_k8s_service_account))
    error_message = "mlflow_k8s_service_account must be a valid Kubernetes service account name."
  }
}

variable "mlflow_gcp_service_account_email" {
  description = "MLflow GCP service account email from terraform/envs/dev output. Empty value derives the dev default name."
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

variable "mlflow_viewer_user_emails" {
  description = "Google accounts granted namespace-scoped read (view) plus pods/portforward on the mlflow namespace, for MLflow UI validation. Keep real values in local terraform.tfvars only."
  type        = set(string)
  default     = []

  validation {
    condition = alltrue([
      for e in var.mlflow_viewer_user_emails :
      can(regex("^[^@]+@[^@]+\\.[^@]+$", e)) && !strcontains(e, ":")
    ])
    error_message = "Each item must be an email without a user: prefix."
  }
}
