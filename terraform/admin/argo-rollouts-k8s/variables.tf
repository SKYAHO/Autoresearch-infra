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

variable "rollouts_namespace" {
  description = "Argo Rollouts controller namespace."
  type        = string
  default     = "argo-rollouts"

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.rollouts_namespace))
    error_message = "rollouts_namespace must be a valid Kubernetes namespace name."
  }
}

variable "cluster_services_cidr" {
  description = "GKE services 2차 대역 (#122). kube-dns/kubernetes.default VIP egress를 ipBlock으로 허용. dev root의 gke_services_cidr와 일치해야 한다."
  type        = string

  validation {
    condition     = can(cidrhost(var.cluster_services_cidr, 0))
    error_message = "cluster_services_cidr must be a valid CIDR in a.b.c.d/n form."
  }
}

variable "cluster_master_cidr" {
  description = "GKE control plane /28 CIDR (#138 패턴). K8s API 443의 post-DNAT 목적지 대비. dev root의 gke_master_ipv4_cidr와 일치해야 한다."
  type        = string

  validation {
    condition     = can(cidrhost(var.cluster_master_cidr, 0))
    error_message = "cluster_master_cidr must be a valid CIDR in a.b.c.d/n form."
  }
}
