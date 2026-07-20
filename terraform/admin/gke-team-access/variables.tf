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

variable "artifact_registry_repository_id" {
  description = "Artifact Registry Docker repository id used for the temporary training-image writer grant (#256)."
  type        = string
  default     = "autoresearch-dev-docker"
}

variable "training_image_ar_writer_emails" {
  description = "학습 이미지(autoresearch-training) 수동 push용으로 autoresearch-dev-docker 저장소 범위 roles/artifactregistry.writer를 받는 계정(#185/#256). push 자동화 전까지는 담당자를 명시해 유지한다(#266) — 비워두고 apply하면 라이브 권한이 사라져 수동 push가 깨진다. 자동화 후 회수하며, 항구적 push 경로는 application_pusher WIF SA. Keep real values in local terraform.tfvars only."
  type        = set(string)
  default     = []

  validation {
    condition = alltrue([
      for e in var.training_image_ar_writer_emails :
      can(regex("^[^@]+@[^@]+\\.[^@]+$", e)) && !strcontains(e, ":")
    ])
    error_message = "Each item must be an email without a user: prefix."
  }
}

variable "cloud_build_staging_bucket" {
  description = "Cloud Build source staging bucket granted to team members (#266). Empty value derives the auto-created <project_id>_cloudbuild bucket."
  type        = string
  default     = ""
}

variable "db_password_secret_id" {
  description = "Secret Manager secret id holding the Airflow metadata DB password (#266). Team members get resource-level secretAccessor on this one secret only."
  type        = string
  default     = "autoresearch-dev-db-password"
}

variable "name_prefix" {
  description = "Resource name prefix used by terraform/envs/dev (#269). Must match that root's name_prefix so the Cloud Build builder SA email derives correctly."
  type        = string
  default     = "autoresearch"
}

variable "cloud_build_builder_service_account_email" {
  description = "Dedicated Cloud Build runtime SA that team members may run builds as (#269). Empty value derives <name_prefix>-cloud-build@<project_id>.iam.gserviceaccount.com."
  type        = string
  default     = ""
}
