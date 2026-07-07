variable "project_id" {
  description = "GCP project id for bootstrap infrastructure (state bucket, WIF, CI SA)."
  type        = string
}

variable "github_repository" {
  description = "GitHub repository allowed to impersonate the CI SA via WIF (owner/name)."
  type        = string
  default     = "SKYAHO/Autoresearch-infra"
}

variable "region" {
  description = "Location for the Terraform state GCS bucket."
  type        = string
  default     = "asia-northeast3"
}
