variable "project_id" {
  description = "GCP project id that hosts the dev GKE cluster."
  type        = string
}

variable "region" {
  description = "Default GCP region."
  type        = string
}

variable "zone" {
  description = "GKE cluster zone."
  type        = string
}

variable "gke_cluster_name" {
  description = "Existing dev GKE cluster name."
  type        = string
}

variable "resource_prefix" {
  description = "Resource prefix used by terraform/envs/dev."
  type        = string
}

# terraform/envs/dev의 actions_runner_namespace/actions_runner_controller_ksa
# 기본값과 일치해야 GSA Workload Identity 바인딩 principal이 실제 KSA와 맞는다.
variable "actions_runner_namespace" {
  description = "셀프 호스티드 러너(ARC) 전용 Kubernetes namespace(#533)."
  type        = string
  default     = "actions-runner"

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.actions_runner_namespace))
    error_message = "actions_runner_namespace must be a valid Kubernetes namespace name."
  }
}

variable "actions_runner_controller_ksa" {
  description = "ARC 컨트롤러 매니저 Pod의 Kubernetes service account 이름. terraform/envs/dev의 GSA와 Workload Identity로 연결된다."
  type        = string
  default     = "actions-runner-controller"

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.actions_runner_controller_ksa))
    error_message = "actions_runner_controller_ksa must be a valid Kubernetes service account name."
  }
}

# 러너(listener/ephemeral runner) Pod 신원. GCP API를 직접 호출하지 않으므로
# GSA를 공유하지 않고 WI annotation도 붙이지 않는다 — automount만 끈다.
variable "actions_runner_listener_ksa" {
  description = "ARC 러너(listener/ephemeral runner) Pod의 Kubernetes service account 이름."
  type        = string
  default     = "actions-runner-listener"

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.actions_runner_listener_ksa))
    error_message = "actions_runner_listener_ksa must be a valid Kubernetes service account name."
  }
}

variable "actions_runner_controller_gcp_service_account_email" {
  description = "ARC 컨트롤러 GCP service account email from terraform/envs/dev output. Empty value derives the dev default name."
  type        = string
  default     = ""
}

variable "cluster_services_cidr" {
  description = "GKE services secondary CIDR used to allow service VIP traffic such as kube-dns and the in-cluster Kubernetes API."
  type        = string

  validation {
    condition     = can(cidrhost(var.cluster_services_cidr, 0))
    error_message = "cluster_services_cidr must be a valid CIDR in a.b.c.d/n form."
  }
}

variable "private_googleapis_cidr" {
  description = "Private Google Access CIDR used for restricted.googleapis.com."
  type        = string

  validation {
    condition     = can(cidrhost(var.private_googleapis_cidr, 0))
    error_message = "private_googleapis_cidr must be a valid CIDR in a.b.c.d/n form."
  }
}

# scale-set chart의 maxRunners 값과 짝을 이뤄야 한다 — Task 3
# deploy/actions-runner-scale-set/values.yaml의 maxRunners를 이 값과 함께 바꾼다.
variable "actions_runner_max_pods" {
  description = "actions-runner namespace pods ResourceQuota 상한. scale-set chart maxRunners와 짝(pair)을 이룬다."
  type        = number
  default     = 4
}
