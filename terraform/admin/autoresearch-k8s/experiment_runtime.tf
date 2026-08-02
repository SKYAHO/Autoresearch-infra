# #485 paired Feast 실험 전용 Kubernetes 격리 경계.
# 첫 변경에서는 observer read만 제공하고 Job 생성은 admission 경계가 준비될 때까지
# fail-closed로 유지한다. 실제 Job manifest는 Airflow 저장소가 후속 변경에서 소유한다.

data "kubernetes_service_v1" "experiment_runtime_kube_dns" {
  metadata {
    name      = "kube-dns"
    namespace = "kube-system"
  }
}

resource "kubernetes_namespace_v1" "experiment_runtime" {
  metadata {
    name = var.experiment_runtime_k8s_namespace
    labels = {
      "app.kubernetes.io/name"             = "experiment-runtime"
      "app.kubernetes.io/part-of"          = "autoresearch-experiments"
      "pod-security.kubernetes.io/enforce" = "restricted"
      "pod-security.kubernetes.io/audit"   = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"
    }
  }
}

resource "kubernetes_service_account_v1" "experiment_runtime" {
  metadata {
    name      = var.experiment_runtime_k8s_service_account
    namespace = kubernetes_namespace_v1.experiment_runtime.metadata[0].name
    annotations = {
      "iam.gke.io/gcp-service-account" = local.experiment_runtime_gcp_service_account_email
    }
  }

  # 이 KSA에는 RoleBinding이 없어 Kubernetes API 주체가 될 필요가 없다. Workload
  # Identity의 GCP 토큰 교환은 GKE metadata server 경로라 default token volume이
  # 필요하지 않으므로, 명시적으로 꺼서 "runtime KSA는 K8s API 주체가 아니다"를
  # 코드로 강제한다(같은 root의 rerank_loadtest.tf와 동일 기준).
  #
  # 주의: 이 값은 Pod spec이 되돌릴 수 있는 기본값이다. Job 생성이 활성화되는
  # 후속 변경에서는 #484처럼 admission 정책으로 automountServiceAccountToken을
  # 함께 막아야 경계가 실제로 강제된다.
  automount_service_account_token = false
}

# baseline/candidate 두 쌍을 동시에 수용하되 namespace 전체 사용량은 네 Job/Pod와
# 4 vCPU/8 GiB request, 8 vCPU/16 GiB limit를 넘지 못한다.
resource "kubernetes_resource_quota_v1" "experiment_runtime" {
  metadata {
    name      = "experiment-runtime-quota"
    namespace = kubernetes_namespace_v1.experiment_runtime.metadata[0].name
  }

  spec {
    hard = {
      "count/jobs.batch" = "4"
      "pods"             = "4"
      "requests.cpu"     = "4"
      "requests.memory"  = "8Gi"
      "limits.cpu"       = "8"
      "limits.memory"    = "16Gi"
    }
  }
}

resource "kubernetes_limit_range_v1" "experiment_runtime" {
  metadata {
    name      = "experiment-runtime-limits"
    namespace = kubernetes_namespace_v1.experiment_runtime.metadata[0].name
  }

  spec {
    limit {
      type = "Container"
      default_request = {
        cpu    = "1"
        memory = "2Gi"
      }
      default = {
        cpu    = "2"
        memory = "4Gi"
      }
      max = {
        cpu    = "2"
        memory = "4Gi"
      }
    }
  }
}

# Airflow의 in-cluster KSA만 종료 상태와 로그를 관찰한다. ValidatingAdmissionPolicy가
# KSA, image digest, deadline/TTL을 강제하기 전에는 jobs.create를 절대 추가하지 않는다.
resource "kubernetes_role_v1" "experiment_runtime_airflow_observer" {
  metadata {
    name      = "experiment-runtime-airflow-observer"
    namespace = kubernetes_namespace_v1.experiment_runtime.metadata[0].name
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
}

resource "kubernetes_role_binding_v1" "experiment_runtime_airflow_observer" {
  metadata {
    name      = "experiment-runtime-airflow-observer"
    namespace = kubernetes_namespace_v1.experiment_runtime.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.experiment_runtime_airflow_observer.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = var.airflow_k8s_service_account
    namespace = var.airflow_k8s_namespace
  }
}

# 실험 Job은 inbound traffic을 받지 않는다.
resource "kubernetes_network_policy_v1" "experiment_runtime_ingress" {
  metadata {
    name      = "experiment-runtime-ingress"
    namespace = kubernetes_namespace_v1.experiment_runtime.metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress"]
  }
}

# DNS, Workload Identity metadata server와 Private Google APIs VIP만 허용한다.
# Redis PSC, Cloud SQL, MLflow Service 및 외부 HTTPS 목적지는 의도적으로 없다.
resource "kubernetes_network_policy_v1" "experiment_runtime_egress" {
  metadata {
    name      = "experiment-runtime-egress"
    namespace = kubernetes_namespace_v1.experiment_runtime.metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Egress"]

    # Calico의 Service DNAT 전후 평가를 모두 수용하되 kube-dns 하나로만 좁힌다.
    egress {
      to {
        ip_block {
          cidr = "${data.kubernetes_service_v1.experiment_runtime_kube_dns.spec[0].cluster_ip}/32"
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

        pod_selector {
          match_labels = {
            "k8s-app" = "kube-dns"
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

  lifecycle {
    precondition {
      condition = (
        try(data.kubernetes_service_v1.experiment_runtime_kube_dns.spec[0].type, "") == "ClusterIP" &&
        try(data.kubernetes_service_v1.experiment_runtime_kube_dns.spec[0].cluster_ip, "") != "" &&
        try(data.kubernetes_service_v1.experiment_runtime_kube_dns.spec[0].cluster_ip, "") != "None"
      )
      error_message = "kube-dns must be an existing ClusterIP Service before the experiment runtime egress policy can be applied."
    }
  }
}
