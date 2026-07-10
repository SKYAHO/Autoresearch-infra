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
