variable "project_id" {
  description = "GCP project id where team members need GKE clusterViewer access."
  type        = string
}

variable "region" {
  description = "Default GCP region for provider operations."
  type        = string
  default     = "asia-northeast3"
}

variable "team_member_emails" {
  description = "Google accounts granted roles/container.clusterViewer. Keep real values in local terraform.tfvars only."
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
