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

variable "cluster_services_cidr" {
  description = "GKE services 2차 대역 (#122). service VIP 경유 egress(DNS/redis/repo-server)를 ipBlock으로 허용하는 데 사용. dev root의 gke_services_cidr와 일치해야 한다."
  type        = string
  default     = "172.16.128.0/24"

  validation {
    condition     = can(cidrhost(var.cluster_services_cidr, 0))
    error_message = "cluster_services_cidr must be a valid CIDR in a.b.c.d/n form."
  }
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

variable "infra_repo_url" {
  description = "이 저장소(infra) Git URL(#183). ArgoCD가 deploy/ umbrella chart를 읽는 source. public이라 자격증명 불필요."
  type        = string
  default     = "https://github.com/SKYAHO/Autoresearch-infra.git"
}

variable "monitoring_namespace" {
  description = "monitoring 스택 namespace(#183). monitoring-k8s root가 소유하며 ArgoCD destination으로 허용한다."
  type        = string
  default     = "monitoring"
}

variable "monitoring_target_revision" {
  description = "monitoring Application이 추적할 infra repo ref(#183). manual sync라 main 추적 무방. 재현성 필요 시 커밋 SHA로 pin."
  type        = string
  default     = "main"
}
