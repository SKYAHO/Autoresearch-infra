variable "project_id" {
  description = "GCP project id for bootstrap infrastructure (state bucket, WIF, CI SA)."
  type        = string
}

variable "github_repository" {
  description = "GitHub repository allowed to impersonate the CI SA via WIF (owner/name)."
  type        = string
  default     = "SKYAHO/Autoresearch-infra"
}

variable "allowed_github_repositories" {
  description = "GitHub repositories allowed to obtain an OIDC token from this WIF provider (owner/name list). The CI SA impersonation is still restricted to var.github_repository by a separate IAM binding."
  type        = list(string)
  default = [
    "SKYAHO/Autoresearch-infra",
    "SKYAHO/Autoresearch-airflow",
    "SKYAHO/Autoresearch",
  ]
}

variable "feast_apply_github_repository" {
  description = "GitHub repository allowed to obtain Feast apply WIF tokens (owner/name). Each provider also requires its matching GitHub Environment."
  type        = string
  default     = "SKYAHO/Autoresearch"
}

variable "feast_apply_workflow_ref" {
  description = "Exact GitHub Actions workflow_ref allowed to obtain Feast apply WIF tokens."
  type        = string
  default     = "SKYAHO/Autoresearch/.github/workflows/feast-apply.yml@refs/heads/main"
}

variable "region" {
  description = "Location for the Terraform state GCS bucket."
  type        = string
  default     = "asia-northeast3"
}

variable "state_bucket_name" {
  description = "Terraform state GCS bucket name. Bucket names are globally unique, so no default can be safe across projects — always pass the value for the project being bootstrapped (#413). Must match the backend bucket in every root's versions.tf."
  type        = string
}
