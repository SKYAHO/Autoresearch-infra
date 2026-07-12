variable "project_id" {
  description = "GCP project id that hosts the dev GKE cluster."
  type        = string
}

variable "region" {
  description = "Default GCP region. KMS keyring(#132)과 같은 리전이어야 한다."
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

variable "vault_namespace" {
  description = "Vault server namespace. dev root vault_k8s_namespace(WI principal)와 일치해야 한다(#132)."
  type        = string
  default     = "vault"

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.vault_namespace))
    error_message = "vault_namespace must be a valid Kubernetes namespace name."
  }
}

variable "vault_release_name" {
  description = "Helm release name. chart가 생성하는 KSA 이름이 release name을 따르므로, dev root vault_k8s_service_account(WI principal)와 일치해야 한다(#132)."
  type        = string
  default     = "vault"
}

variable "vault_chart_version" {
  description = "Pinned hashicorp/vault Helm chart version."
  type        = string
  default     = "0.34.0"
}

variable "vault_values_file_path" {
  description = "Module-relative path for the Vault Helm values file."
  type        = string
  default     = "helm-values/vault.values.yaml"
}

variable "cluster_services_cidr" {
  description = "GKE services 2차 대역 (#122). service VIP 경유 egress(DNS)를 ipBlock으로 허용하는 데 사용. dev root의 gke_services_cidr와 일치해야 한다."
  type        = string
  default     = "172.16.128.0/24"

  validation {
    condition     = can(cidrhost(var.cluster_services_cidr, 0))
    error_message = "cluster_services_cidr must be a valid CIDR in a.b.c.d/n form."
  }
}

variable "ui_ingress_source_cidr" {
  description = "vault server(8200)로 ingress를 허용할 VPC 내부 CIDR (#116 교훈). kubectl port-forward 트래픽이 노드 IP에서 출발하므로 dev subnet 기본."
  type        = string
  default     = "10.10.0.0/20"

  validation {
    condition     = can(cidrhost(var.ui_ingress_source_cidr, 0))
    error_message = "ui_ingress_source_cidr must be a valid CIDR in a.b.c.d/n form."
  }
}

variable "cluster_master_cidr" {
  description = "GKE control plane(master) /28 CIDR (#138). K8s API 443의 post-DNAT 목적지 — dataplane이 post-DNAT 평가로 바뀌는 경우 대비. dev root의 gke_master_ipv4_cidr와 일치해야 한다."
  type        = string
  default     = "172.16.0.0/28"

  validation {
    condition     = can(cidrhost(var.cluster_master_cidr, 0))
    error_message = "cluster_master_cidr must be a valid CIDR in a.b.c.d/n form."
  }
}
