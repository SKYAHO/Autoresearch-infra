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

variable "monitoring_namespace" {
  description = "Kubernetes namespace for Prometheus/Grafana monitoring components."
  type        = string
  default     = "monitoring"

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.monitoring_namespace))
    error_message = "monitoring_namespace must be a valid Kubernetes namespace name."
  }
}

variable "kube_prometheus_stack_release_name" {
  description = "Helm release name for kube-prometheus-stack."
  type        = string
  default     = "kube-prometheus-stack"
}

variable "kube_prometheus_stack_chart_version" {
  description = "Pinned kube-prometheus-stack Helm chart version."
  type        = string
  default     = "87.12.1"
}

variable "grafana_admin_existing_secret_name" {
  description = "Existing Kubernetes Secret name that contains Grafana admin credentials. Secret payload is managed outside Terraform."
  type        = string
  default     = "grafana-admin-credentials"
}

variable "grafana_admin_user_key" {
  description = "Key in grafana_admin_existing_secret_name that stores the Grafana admin username."
  type        = string
  default     = "admin-user"
}

variable "grafana_admin_password_key" {
  description = "Key in grafana_admin_existing_secret_name that stores the Grafana admin password."
  type        = string
  default     = "admin-password"
}

variable "grafana_viewer_user_emails" {
  description = "Google accounts granted minimal monitoring namespace access for Grafana port-forward. Keep real values in local terraform.tfvars only."
  type        = set(string)
  default     = []

  validation {
    condition = alltrue([
      for e in var.grafana_viewer_user_emails :
      can(regex("^[^@]+@[^@]+\\.[^@]+$", e)) && !strcontains(e, ":")
    ])
    error_message = "Each item must be an email without a user: prefix."
  }
}
