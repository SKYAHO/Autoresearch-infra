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

variable "elastic_namespace" {
  description = "ECK operator + Elasticsearch/Kibana namespace (#96 설계 — 단일 namespace 최소 구성)."
  type        = string
  default     = "elastic"

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.elastic_namespace))
    error_message = "elastic_namespace must be a valid Kubernetes namespace name."
  }
}

variable "eck_release_name" {
  description = "Helm release name for the ECK operator."
  type        = string
  default     = "eck-operator"
}

variable "eck_chart_version" {
  description = "Pinned eck-operator Helm chart version."
  type        = string
  default     = "3.4.1"
}

variable "eck_values_file_path" {
  description = "Module-relative path for the ECK operator Helm values file."
  type        = string
  default     = "helm-values/eck-operator.values.yaml"
}

variable "kibana_ingress_source_cidr" {
  description = "Kibana(5601)로 ingress를 허용할 VPC 내부 CIDR. kubectl port-forward 트래픽이 노드 IP에서 출발하므로 dev subnet 기본(#116 교훈)."
  type        = string
  default     = "10.10.0.0/20"

  validation {
    condition     = can(cidrhost(var.kibana_ingress_source_cidr, 0))
    error_message = "kibana_ingress_source_cidr must be a valid CIDR in a.b.c.d/n form."
  }
}

variable "cluster_services_cidr" {
  description = "GKE services 2차 대역 (#122). kube-dns/kubernetes.default VIP egress를 ipBlock으로 허용. dev root의 gke_services_cidr와 일치해야 한다."
  type        = string
  default     = "172.16.128.0/24"

  validation {
    condition     = can(cidrhost(var.cluster_services_cidr, 0))
    error_message = "cluster_services_cidr must be a valid CIDR in a.b.c.d/n form."
  }
}

variable "cluster_master_cidr" {
  description = "GKE control plane /28 CIDR. webhook ingress(control plane → operator)와 K8s API post-DNAT egress 대비(#138 패턴). dev root의 gke_master_ipv4_cidr와 일치해야 한다."
  type        = string
  default     = "172.16.0.0/28"

  validation {
    condition     = can(cidrhost(var.cluster_master_cidr, 0))
    error_message = "cluster_master_cidr must be a valid CIDR in a.b.c.d/n form."
  }
}

variable "elasticsearch_version" {
  description = "Elasticsearch 스택 버전(#98). operator(chart) 버전과 함께 pin하고 upgrade는 operator 먼저(README 버전 고정 기준)."
  type        = string
  default     = "9.2.0"
}

# --- #293 Kibana Google 로그인 (oauth2-proxy + anonymous access) ---

# #323 kibana_anonymous_role 변수는 제거됐다 — Kibana 9.2에서 deprecated된
# elasticsearch_anonymous_user 대신 실제 fileRealm 사용자를 쓰면서, anonymous
# 사용자의 role은 operator 주입 Secret `kibana-anon-user`의 users_roles가 소유한다
# (기본 viewer). 역할 변경은 그 Secret을 수정한다.

variable "kibana_public_base_url" {
  description = "#298 oauth2-proxy 뒤 Kibana가 인식하는 외부 접근 URL. MLflow와 분리한 port-forward라 localhost:4181."
  type        = string
  default     = "http://localhost:4181"
}

variable "oauth2_proxy_image" {
  description = "#293 Kibana 앞단 oauth2-proxy 이미지(pin). MLflow(#232)와 동일 버전."
  type        = string
  default     = "quay.io/oauth2-proxy/oauth2-proxy:v7.7.1"
}
