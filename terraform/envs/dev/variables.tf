variable "project_id" {
  description = "GCP project id for the dev environment."
  type        = string
}

variable "region" {
  description = "Default GCP region for dev resources."
  type        = string
  default     = "asia-northeast3"
}

variable "zone" {
  description = "Default GCP zone for zonal dev resources."
  type        = string
  default     = "asia-northeast3-a"
}

variable "environment" {
  description = "Deployment environment name."
  type        = string
  default     = "dev"

  validation {
    condition     = var.environment == "dev"
    error_message = "This Terraform root module is only for the dev environment."
  }
}

variable "name_prefix" {
  description = "Prefix used for dev GCP resource names."
  type        = string
  default     = "autoresearch"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,30}$", var.name_prefix))
    error_message = "name_prefix must start with a lowercase letter and contain only lowercase letters, numbers, and hyphens."
  }
}

variable "labels" {
  description = "Additional labels applied to supported GCP resources."
  type        = map(string)
  default     = {}
}

variable "dev_subnet_cidr" {
  description = "Primary CIDR range for the dev subnet."
  type        = string
  default     = "10.10.0.0/20"

  validation {
    condition     = can(cidrhost(var.dev_subnet_cidr, 0))
    error_message = "dev_subnet_cidr must be a valid CIDR in a.b.c.d/n form."
  }
}

variable "enable_private_google_access" {
  description = "Enable Private Google Access on the dev subnet."
  type        = bool
  default     = true
}

variable "db_database_version" {
  description = "Cloud SQL database version."
  type        = string
  default     = "POSTGRES_15"
}

variable "db_tier" {
  description = "Cloud SQL machine tier (dev 최소 비용)."
  type        = string
  default     = "db-f1-micro"
}

variable "db_name" {
  description = "Name of the dev application database."
  type        = string
  default     = "autoresearch"
}

variable "db_app_user" {
  description = "Application user for the dev database."
  type        = string
  default     = "app"
}

variable "sql_deletion_protection" {
  description = "Enable Cloud SQL instance deletion protection (GCP-side). dev는 false 권장."
  type        = bool
  default     = false
}

variable "private_services_cidr" {
  description = "CIDR for Cloud SQL private services access (VPC peering). Must not overlap dev_subnet_cidr."
  type        = string
  default     = "10.20.0.0/20"

  validation {
    condition     = can(cidrhost(var.private_services_cidr, 0))
    error_message = "private_services_cidr must be a valid CIDR in a.b.c.d/n form."
  }
}

