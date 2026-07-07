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

variable "gke_master_ipv4_cidr" {
  description = "Private GKE 컨트롤 플레인용 /28 CIDR. dev subnet/private services와 미중복."
  type        = string

  validation {
    condition     = can(cidrhost(var.gke_master_ipv4_cidr, 0))
    error_message = "gke_master_ipv4_cidr must be a valid CIDR in a.b.c.d/n form."
  }
}

variable "gke_pods_cidr" {
  description = "GKE pods용 서브넷 2차 대역. dev subnet/private services/master CIDR과 미중복."
  type        = string
  default     = "__VG_IPV4_d1c0e8a2__/20"

  validation {
    condition     = can(cidrhost(var.gke_pods_cidr, 0))
    error_message = "gke_pods_cidr must be a valid CIDR in a.b.c.d/n form."
  }
}

variable "gke_services_cidr" {
  description = "GKE services용 서브넷 2차 대역. 다른 대역과 미중복."
  type        = string
  default     = "__VG_IPV4_b7e1f903__/24"

  validation {
    condition     = can(cidrhost(var.gke_services_cidr, 0))
    error_message = "gke_services_cidr must be a valid CIDR in a.b.c.d/n form."
  }
}

variable "gke_machine_type" {
  description = "노드 머신 타입 (dev 최소 비용)."
  type        = string
  default     = "e2-small"
}

variable "gke_node_count_min" {
  description = "노드풀 autoscaling 최소 노드 수."
  type        = number
  default     = 1
}

variable "gke_node_count_max" {
  description = "노드풀 autoscaling 최대 노드 수."
  type        = number
  default     = 2
}

variable "gke_node_disk_size" {
  description = "노드 부트 디스크 크기(GB)."
  type        = number
  default     = 30
}

variable "gke_node_disk_type" {
  description = "노드 부트 디스크 타입."
  type        = string
  default     = "pd-standard"
}

variable "gke_release_channel" {
  description = "GKE release channel (관리형 업그레이드)."
  type        = string
  default     = "REGULAR"
}

variable "gke_deletion_protection" {
  description = "GKE cluster 삭제 보호. dev는 false 권장."
  type        = bool
  default     = false
}

variable "master_authorized_networks" {
  description = "GKE 마스터 API에 접근 허용할 CIDR 목록. kubectl을 쓰려면 본인 IP를 tfvars에 추가."
  type        = list(string)
  default     = []
}

variable "gke_app_k8s_namespace" {
  description = "Workload Identity로 매핑할 Kubernetes namespace."
  type        = string
  default     = "autoresearch"
}

variable "gke_app_k8s_service_account" {
  description = "Workload Identity로 매핑할 Kubernetes service account."
  type        = string
  default     = "autoresearch-app"
}

variable "raw_data_bucket_location" {
  description = "원본 데이터 GCS bucket location. dev는 기본 region과 동일한 asia-northeast3."
  type        = string
  default     = "asia-northeast3"
}

variable "raw_data_bucket_storage_class" {
  description = "원본 데이터 GCS bucket storage class."
  type        = string
  default     = "STANDARD"
}

variable "raw_data_noncurrent_version_retention_days" {
  description = "GCS raw bucket noncurrent object version 보존 일수(dev 비용 방지)."
  type        = number
  default     = 30
}

variable "bigquery_location" {
  description = "dev BigQuery dataset location."
  type        = string
  default     = "asia-northeast3"
}

variable "bigquery_delete_contents_on_destroy" {
  description = "BigQuery dataset destroy 시 table/view contents 삭제 허용 여부. dev도 기본 false."
  type        = bool
  default     = false
}

variable "feast_bucket_location" {
  description = "Feast registry/staging GCS bucket location."
  type        = string
  default     = "asia-northeast3"
}

variable "feast_bucket_storage_class" {
  description = "Feast registry/staging GCS bucket storage class."
  type        = string
  default     = "STANDARD"
}

variable "feast_registry_noncurrent_version_retention_days" {
  description = "Feast registry bucket noncurrent object version 보존 일수(dev 비용 방지)."
  type        = number
  default     = 30
}

variable "feast_staging_object_retention_days" {
  description = "Feast staging bucket 임시 object 보존 일수(dev 비용 방지)."
  type        = number
  default     = 7
}
