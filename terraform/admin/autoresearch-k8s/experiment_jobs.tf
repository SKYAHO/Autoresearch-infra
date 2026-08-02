# Auto Research 실험은 기존 앱·Agent Orchestration namespace와 분리한다. Job 생성
# 권한이 있는 API가 임의 Pod 사양을 만들 수 있는 위험을 줄이기 위해 Pod Security,
# quota, LimitRange, NetworkPolicy와 전용 KSA를 한 경계에서 함께 관리한다.
resource "kubernetes_namespace_v1" "experiment_jobs" {
  metadata {
    name = var.experiment_job_namespace
    labels = {
      "app.kubernetes.io/name"             = "autoresearch-experiments"
      "app.kubernetes.io/part-of"          = "auto-research"
      "pod-security.kubernetes.io/enforce" = "restricted"
      # 현재 live GKE control plane v1.35를 기준으로 고정한다. 다음 마이너
      # 업그레이드 전에는 runbook의 PSA dry-run과 Job image 호환성을 확인한 뒤
      # 의도적으로 이 값을 올린다.
      "pod-security.kubernetes.io/enforce-version" = "v1.35"
      "pod-security.kubernetes.io/audit"           = "restricted"
      "pod-security.kubernetes.io/audit-version"   = "latest"
      "pod-security.kubernetes.io/warn"            = "restricted"
      "pod-security.kubernetes.io/warn-version"    = "latest"
    }
  }
}

# GKE metadata server는 source Pod identity와 KSA annotation으로 Workload Identity를
# 교환하므로 Kubernetes API token을 컨테이너에 마운트할 필요가 없다. 저신뢰 에이전트에
# 불필요한 Kubernetes 자격 증명을 노출하지 않기 위해 명시적으로 비활성화한다.
resource "kubernetes_service_account_v1" "experiment_job" {
  metadata {
    name      = var.experiment_job_k8s_service_account
    namespace = kubernetes_namespace_v1.experiment_jobs.metadata[0].name
    annotations = {
      "iam.gke.io/gcp-service-account" = local.experiment_job_gcp_service_account_email
    }
  }

  automount_service_account_token = false
}

# 실험은 일반 앱 pool이 아니라 batch-od pool에 고정한다. 이 pool은 Action Log shard
# KPO와 공유하므로, 생성 권한 활성화 전에 별도의 용량·우선순위 계획을 승인해야 한다.
# quota는 pool의
# e2-standard-2 두 노드(min 0/max 2)에서 각각 한 Job이 안정적으로 실행되는
# 보수적 상한이다. 완료 Job도 TTL 전에는 quota에 포함되므로 무한 재시도·대량 제출로
# batch 비용이 늘어나는 경로를 차단한다.
resource "kubernetes_resource_quota_v1" "experiment_jobs" {
  metadata {
    name      = "experiment-jobs-quota"
    namespace = kubernetes_namespace_v1.experiment_jobs.metadata[0].name
  }

  spec {
    hard = {
      "count/jobs.batch" = "2"
      "pods"             = "2"
      "requests.cpu"     = "2"
      "requests.memory"  = "4Gi"
      "limits.cpu"       = "2"
      "limits.memory"    = "4Gi"
    }
  }

  depends_on = [kubernetes_namespace_v1.experiment_jobs]
}

resource "kubernetes_limit_range_v1" "experiment_jobs" {
  metadata {
    name      = "experiment-jobs-limits"
    namespace = kubernetes_namespace_v1.experiment_jobs.metadata[0].name
  }

  spec {
    limit {
      type = "Container"
      default = {
        cpu    = "500m"
        memory = "1Gi"
      }
      default_request = {
        cpu    = "500m"
        memory = "1Gi"
      }
      max = {
        cpu    = "1"
        memory = "2Gi"
      }
    }
  }

  depends_on = [kubernetes_namespace_v1.experiment_jobs]
}

# API는 Job·Pod 상태와 log만 읽는다. Secret·exec·ServiceAccount·Role 수정 권한은
# 의도적으로 포함하지 않는다.
resource "kubernetes_role_v1" "experiment_job_observer" {
  metadata {
    name      = "experiment-job-observer"
    namespace = kubernetes_namespace_v1.experiment_jobs.metadata[0].name
  }

  rule {
    api_groups = ["batch"]
    resources  = ["jobs"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods/log"]
    verbs      = ["get"]
  }

  # ImagePullBackOff·FailedScheduling·Job Pod 생성 quota 초과의 상세 원인은 Event에
  # 남는다. namespace 범위의 읽기 전용으로만 허용하며, API는 자기 실험 ID의
  # involvedObject만 사용자 상태에 연결해야 한다.
  rule {
    api_groups = ["", "events.k8s.io"]
    resources  = ["events"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_role_binding_v1" "experiment_job_observer" {
  metadata {
    name      = "experiment-job-observer"
    namespace = kubernetes_namespace_v1.experiment_jobs.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.experiment_job_observer.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.agent_orchestration_api.metadata[0].name
    namespace = kubernetes_namespace_v1.autoresearch.metadata[0].name
  }
}

# Kubernetes RBAC만으로는 Job 내부 image·volume·환경 변수를 제한할 수 없다. 따라서
# 이 Role은 고정 템플릿·허용 digest·admission 검증이 앱/클러스터에 적용됐다는 별도
# 검토가 끝날 때까지 기본 false로 유지한다.
resource "kubernetes_role_v1" "experiment_job_creator" {
  for_each = var.enable_experiment_job_creation ? toset(["enabled"]) : toset([])

  metadata {
    name      = "experiment-job-creator"
    namespace = kubernetes_namespace_v1.experiment_jobs.metadata[0].name
  }

  rule {
    api_groups = ["batch"]
    resources  = ["jobs"]
    verbs      = ["create"]
  }
}

resource "kubernetes_role_binding_v1" "experiment_job_creator" {
  for_each = var.enable_experiment_job_creation ? toset(["enabled"]) : toset([])

  metadata {
    name      = "experiment-job-creator"
    namespace = kubernetes_namespace_v1.experiment_jobs.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.experiment_job_creator[each.key].metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.agent_orchestration_api.metadata[0].name
    namespace = kubernetes_namespace_v1.autoresearch.metadata[0].name
  }
}

# 실험 Job에는 inbound traffic이 필요 없다.
resource "kubernetes_network_policy_v1" "experiment_jobs_ingress" {
  metadata {
    name      = "experiment-jobs-ingress"
    namespace = kubernetes_namespace_v1.experiment_jobs.metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress"]
  }
}

# 기본 egress를 차단하고 DNS, Workload Identity metadata, 결과 GCS 업로드용
# Private Google Access만 허용한다. Redis·Cloud SQL·MLflow·외부 HTTPS는 이 MVP에
# 포함하지 않는다.
resource "kubernetes_network_policy_v1" "experiment_jobs_egress" {
  metadata {
    name      = "experiment-jobs-egress"
    namespace = kubernetes_namespace_v1.experiment_jobs.metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Egress"]

    egress {
      to {
        ip_block {
          cidr = var.cluster_services_cidr
        }
      }

      ports {
        protocol = "UDP"
        port     = "53"
      }

      ports {
        protocol = "TCP"
        port     = "53"
      }
    }

    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "kube-system"
          }
        }
      }

      ports {
        protocol = "UDP"
        port     = "53"
      }

      ports {
        protocol = "TCP"
        port     = "53"
      }
    }

    egress {
      to {
        ip_block {
          cidr = "169.254.169.254/32"
        }
      }

      ports {
        protocol = "TCP"
        port     = "80"
      }
    }

    egress {
      to {
        ip_block {
          cidr = "169.254.169.252/32"
        }
      }

      ports {
        protocol = "TCP"
        port     = "987"
      }

      ports {
        protocol = "TCP"
        port     = "988"
      }
    }

    egress {
      to {
        ip_block {
          cidr = var.private_googleapis_cidr
        }
      }

      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }

  depends_on = [kubernetes_namespace_v1.experiment_jobs]
}
