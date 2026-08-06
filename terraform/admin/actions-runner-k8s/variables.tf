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

# ephemeral runner(실제 GH Actions job을 실행하는) Pod 전용 신원 — chart의
# template.spec.serviceAccountName에만 연결된다(#533 리뷰). AutoscalingListener
# Pod는 이 KSA를 쓰지 않는다 — gha-runner-scale-set chart가 자체 SA(listener
# RBAC 포함)를 자동 생성한다. GCP API를 직접 호출하지 않으므로 GSA를 공유하지
# 않고 WI annotation도 붙이지 않는다 — automount만 끈다.
variable "actions_runner_runner_ksa" {
  description = "ARC ephemeral runner Pod(template.spec)의 Kubernetes service account 이름. AutoscalingListener Pod는 별도(chart 자동 생성)."
  type        = string
  default     = "actions-runner-runner"

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.actions_runner_runner_ksa))
    error_message = "actions_runner_runner_ksa must be a valid Kubernetes service account name."
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
  # autoresearch-k8s와 동일한 canonical 값(#533 리뷰) — 카탈로그 values 해시에
  # 별도로 없어도 CI apply(-input=false)가 값 없이 실패하지 않는다.
  default = "199.36.153.8/30"

  validation {
    condition     = can(cidrhost(var.private_googleapis_cidr, 0)) && var.private_googleapis_cidr == "199.36.153.8/30"
    error_message = "private_googleapis_cidr must be the canonical Private Google APIs CIDR 199.36.153.8/30."
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

# scale-set chart의 maxRunners 값과 짝을 이뤄야 한다 — Task 3
# deploy/actions-runner-scale-set/values.yaml의 maxRunners를 이 값과 함께 바꾼다.
variable "actions_runner_max_pods" {
  description = "actions-runner namespace pods ResourceQuota 상한(PoC 스케일셋 몫). scale-set chart maxRunners와 짝(pair)을 이룬다."
  type        = number
  default     = 4
}

# #541 5단계: deploy/actions-runner-scale-set-feast-dev/values.yaml의
# maxRunners와 짝을 이룬다. feast apply는 동시 실행이 드물어 PoC보다 낮게 잡는다.
variable "feast_apply_dev_max_pods" {
  description = "feast-apply-dev 스케일셋 몫 ResourceQuota 상한."
  type        = number
  default     = 2
}

variable "feast_apply_prod_max_pods" {
  description = "feast-apply-prod 스케일셋 몫 ResourceQuota 상한."
  type        = number
  default     = 2
}

# #541 5단계: feast-apply-prod 러너 스케일셋 egress 전용. 값은
# terraform/admin/autoresearch-k8s/variables.tf와 반드시 일치해야 한다(같은
# Redis Cluster를 가리킨다).
variable "redis_psc_subnet_cidr" {
  description = "Redis Cluster PSC subnet CIDR from terraform/envs/dev redis_psc_subnet_cidr output."
  type        = string
  default     = "10.10.16.0/29"

  validation {
    condition     = can(cidrhost(var.redis_psc_subnet_cidr, 0)) && can(regex("/29$", var.redis_psc_subnet_cidr))
    error_message = "redis_psc_subnet_cidr must be a valid /29 CIDR."
  }
}

variable "redis_discovery_port" {
  description = "Memorystore for Redis Cluster discovery endpoint port."
  type        = number
  default     = 6379

  validation {
    condition     = var.redis_discovery_port >= 1 && var.redis_discovery_port <= 65535 && floor(var.redis_discovery_port) == var.redis_discovery_port
    error_message = "redis_discovery_port must be an integer between 1 and 65535."
  }
}

variable "redis_node_port_start" {
  description = "First Redis Cluster data node port returned by cluster topology."
  type        = number
  default     = 11000

  validation {
    condition     = var.redis_node_port_start >= 1 && var.redis_node_port_start <= 65535 && floor(var.redis_node_port_start) == var.redis_node_port_start
    error_message = "redis_node_port_start must be an integer between 1 and 65535."
  }
}

variable "redis_node_port_end" {
  description = "Last Redis Cluster data node port returned by cluster topology."
  type        = number
  default     = 13047

  validation {
    condition     = var.redis_node_port_end >= 1 && var.redis_node_port_end <= 65535 && floor(var.redis_node_port_end) == var.redis_node_port_end
    error_message = "redis_node_port_end must be an integer between 1 and 65535."
  }
}

# terraform/admin/autoresearch-k8s의 feast_apply_identities와 같은 GSA를
# 재사용한다(#424, 신규 GSA 없음). 빈 값은 그 root의 local part 파생 규칙과
# 동일하게 derive한다.
variable "feast_apply_dev_gcp_service_account_email" {
  description = "feast-apply-dev 러너 스케일셋 KSA가 가리킬 GSA email. Empty value derives the dev default name."
  type        = string
  default     = ""
}

variable "feast_apply_prod_gcp_service_account_email" {
  description = "feast-apply-prod 러너 스케일셋 KSA가 가리킬 GSA email. Empty value derives the prod default name."
  type        = string
  default     = ""
}
