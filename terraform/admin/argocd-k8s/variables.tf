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
  description = "Module-relative path for the ArgoCD Helm values template consumed by helm_release.argo_cd (templatefile)."
  type        = string
  default     = "helm-values/argo-cd.values.yaml.tftpl"
}

variable "argocd_server_url" {
  description = "#289 ArgoCD가 자기 자신을 인식하는 URL(OIDC redirect 기준). port-forward 접근이라 localhost. Google OAuth client redirect URI(<url>/auth/callback)와 일치해야 한다."
  type        = string
  default     = "https://localhost:8443"
}

variable "argocd_admin_user_emails" {
  description = "#289 ArgoCD role:admin을 부여할 Google 계정 이메일. 실제 값은 로컬 terraform.tfvars에만 두고 Git에 커밋하지 않는다."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for e in var.argocd_admin_user_emails : can(regex("^[^@:[:space:]]+@[^@:[:space:]]+$", e))
    ])
    error_message = "Each admin email must be a bare email without a user: prefix."
  }
}

variable "argocd_readonly_user_emails" {
  description = "#289 ArgoCD role:readonly를 부여할 Google 계정 이메일. 실제 값은 로컬 terraform.tfvars에만 두고 Git에 커밋하지 않는다."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for e in var.argocd_readonly_user_emails : can(regex("^[^@:[:space:]]+@[^@:[:space:]]+$", e))
    ])
    error_message = "Each readonly email must be a bare email without a user: prefix."
  }
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
  description = "monitoring Application이 추적할 infra repo ref(#183). 최초 adopt는 -var로 병합 커밋 SHA를 주입해 렌더가 live와 일치하도록 pin한다(무중단 전제). 기본 main은 파일럿 이후 manual sync 추적용."
  type        = string
  default     = "main"
}

variable "rollouts_namespace" {
  description = "argo-rollouts 스택 namespace. ArgoCD destination으로 허용한다."
  type        = string
  default     = "argo-rollouts"
}

variable "rollouts_target_revision" {
  description = "argo-rollouts Application이 추적할 infra repo ref. 최초 adopt는 -var로 병합 커밋 SHA를 주입해 pin한다."
  type        = string
  default     = "main"
}

variable "mlflow_namespace" {
  description = "#94 MLflow tracking server namespace(mlflow-k8s 소유). ArgoCD destination으로 허용한다."
  type        = string
  default     = "mlflow"
}

variable "mlflow_target_revision" {
  description = "MLflow Application이 추적할 infra repo ref. 최초 sync는 -var로 병합 커밋 SHA를 pin한다."
  type        = string
  default     = "main"
}

variable "app_namespace" {
  description = "#302 Autoresearch 앱 namespace(autoresearch-k8s 소유). ArgoCD destination으로 허용한다."
  type        = string
  default     = "autoresearch"
}

variable "serving_target_revision" {
  description = "Inference Server Application이 추적할 infra repo ref. 최초 sync는 -var로 병합 커밋 SHA를 pin한다."
  type        = string
  default     = "main"
}
