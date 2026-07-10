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

variable "argocd_namespace" {
  description = "Kubernetes namespace reserved for ArgoCD control plane components."
  type        = string
  default     = "argocd"

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.argocd_namespace))
    error_message = "argocd_namespace must be a valid Kubernetes namespace name."
  }
}

variable "argocd_values_file_path" {
  description = "Module-relative path for the ArgoCD Helm values file consumed by helm_release.argo_cd."
  type        = string
  default     = "helm-values/argo-cd.values.yaml"
}

variable "ui_ingress_source_cidr" {
  description = "argocd-server(8080)로 ingress를 허용할 VPC 내부 CIDR (#116). kubectl port-forward 트래픽이 노드 IP에서 출발하므로 dev subnet 기본."
  type        = string
  default     = "10.10.0.0/20"

  validation {
    condition     = can(cidrhost(var.ui_ingress_source_cidr, 0))
    error_message = "ui_ingress_source_cidr must be a valid CIDR in a.b.c.d/n form."
  }
}

variable "argo_cd_release_name" {
  description = "Helm release name for Argo CD."
  type        = string
  default     = "argo-cd"
}

variable "argo_cd_chart_version" {
  description = "Pinned argo-cd Helm chart version."
  type        = string
  default     = "10.1.3"
}
