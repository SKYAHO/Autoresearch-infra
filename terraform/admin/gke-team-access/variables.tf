variable "project_id" {
  description = "GCP project id where team members need GKE, Bastion, and BigQuery access."
  type        = string
}

variable "bigquery_analytics_dataset_id" {
  description = "Dev analytics BigQuery dataset where team members receive dataset-scoped dataEditor."
  type        = string
  default     = "autoresearch_dev_analytics"

  validation {
    condition     = can(regex("^[A-Za-z_][A-Za-z0-9_]*$", var.bigquery_analytics_dataset_id)) && length(var.bigquery_analytics_dataset_id) <= 1024
    error_message = "BigQuery dataset ID must start with a letter or underscore and contain only letters, digits, and underscores."
  }
}

variable "bigquery_feast_offline_store_dataset_id" {
  description = "Dev Feast offline-store BigQuery dataset where team members receive dataset-scoped dataEditor."
  type        = string
  default     = "feast_offline_store"

  validation {
    condition     = can(regex("^[A-Za-z_][A-Za-z0-9_]*$", var.bigquery_feast_offline_store_dataset_id)) && length(var.bigquery_feast_offline_store_dataset_id) <= 1024
    error_message = "BigQuery dataset ID must start with a letter or underscore and contain only letters, digits, and underscores."
  }
}

variable "region" {
  description = "Default GCP region for provider operations."
  type        = string
  default     = "asia-northeast3"
}

variable "team_member_emails" {
  description = "Google accounts granted roles/container.viewer (kubectl DNS 엔드포인트 접속 포함). Keep real values in local terraform.tfvars only."
  type        = set(string)
  default     = []

  validation {
    condition = alltrue([
      for e in var.team_member_emails :
      can(regex("^[^@]+@[^@]+\\.[^@]+$", e)) && !strcontains(e, ":")
    ])
    error_message = "Each item must be an email without a user: prefix."
  }
}
