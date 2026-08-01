# #482 리랭킹 serving 부하테스트 전용 경계.
# 앱 저장소의 workflow는 GitHub Actions GSA로 GKE API를 호출하고, k6 Job은
# 이 namespace의 KSA로 serving Service만 호출한다. 실제 GKE 변경은 별도 승인된
# apply에서 수행한다.

locals {
  rerank_loadtest_runner_github_gsa_email = var.rerank_loadtest_runner_github_gsa_email != "" ? var.rerank_loadtest_runner_github_gsa_email : "${var.resource_prefix}-rl-runner@${var.project_id}.iam.gserviceaccount.com"
  rerank_loadtest_snapshot_reader_github_gsa_email = var.rerank_loadtest_snapshot_reader_github_gsa_email != "" ? var.rerank_loadtest_snapshot_reader_github_gsa_email : "${var.resource_prefix}-rl-snapshot@${var.project_id}.iam.gserviceaccount.com"
}

# ArgoCD가 관리하는 serving Service는 이 root의 namespace state와 분리돼 있다.
# ClusterIP를 읽어 pre-DNAT NetworkPolicy에서 `/32`로 정확히 허용한다.
data "kubernetes_service_v1" "autoresearch_serving" {
  metadata {
    name      = "autoresearch-serving"
    namespace = "autoresearch"
  }
}

data "kubernetes_service_v1" "kube_dns" {
  metadata {
    name      = "kube-dns"
    namespace = "kube-system"
  }
}

resource "kubernetes_namespace_v1" "rerank_loadtest" {
  metadata {
    name = var.loadtest_namespace
    labels = {
      "app.kubernetes.io/name"              = "rerank-loadtest"
      "app.kubernetes.io/part-of"           = "benchmarking"
      "pod-security.kubernetes.io/enforce" = "baseline"
      "pod-security.kubernetes.io/audit"   = "baseline"
      "pod-security.kubernetes.io/warn"    = "baseline"
    }
  }
}

resource "kubernetes_service_account_v1" "rerank_loadtest" {
  metadata {
    name      = var.rerank_loadtest_service_account
    namespace = kubernetes_namespace_v1.rerank_loadtest.metadata[0].name
  }

  # k6는 GKE API/GCP API를 호출하지 않는다. Job manifest에서도 false를 명시해
  # default automount 설정이 바뀌어도 서비스 계정 토큰을 파드에 주입하지 않는다.
  automount_service_account_token = false
}

# 한 workflow는 최대 네 Job을 순차 실행하고, candidate 24/200 × baseline/optimized
# 비교 매트릭스의 네 workflow 실행을 같은 보존 기간 안에 기록할 수 있도록 16개까지
# 보관한다. 완료 Job/Pod도 TTL 전에는
# quota에 포함되므로 임의 Job의 수·자원 사용량을 namespace에서 제한한다. 설정
# ConfigMap은 workflow마다 하나의 공유 script와 네 개의 VU 설정을 만들며, 네
# workflow 비교 매트릭스에는 최대 17개가 동시에 남는다. 20개 quota로 이 보존
# 범위를 허용하되, 실수로 ConfigMap을 무한 생성하는 경로는 차단한다. Job
# deadline/TTL 자체는 앱 workflow manifest 계약이며 별도 admission policy 대상이다.
resource "kubernetes_resource_quota_v1" "rerank_loadtest" {
  metadata {
    name      = "rerank-loadtest-quota"
    namespace = kubernetes_namespace_v1.rerank_loadtest.metadata[0].name
  }

  spec {
    hard = {
      "count/configmaps" = "20"
      "count/jobs.batch" = "16"
      "pods"             = "16"
      "requests.cpu"     = "4"
      "requests.memory"  = "4Gi"
      "limits.cpu"       = "16"
      "limits.memory"    = "16Gi"
    }
  }

  depends_on = [kubernetes_namespace_v1.rerank_loadtest]
}

resource "kubernetes_limit_range_v1" "rerank_loadtest" {
  metadata {
    name      = "rerank-loadtest-limits"
    namespace = kubernetes_namespace_v1.rerank_loadtest.metadata[0].name
  }

  spec {
    limit {
      type = "Container"
      default = {
        cpu    = "500m"
        memory = "512Mi"
      }
      default_request = {
        cpu    = "250m"
        memory = "256Mi"
      }
      max = {
        cpu    = "1"
        memory = "1Gi"
      }
    }
  }

  depends_on = [kubernetes_namespace_v1.rerank_loadtest]
}

# GitHub Actions runner가 script/settings ConfigMap과 k6 Job을 생성하고 결과를
# 읽는 최소 권한. ConfigMap delete, pods/exec, Secret, Service 권한은 부여하지 않는다.
resource "kubernetes_role_v1" "rerank_loadtest_runner" {
  metadata {
    name      = "rerank-loadtest-runner"
    namespace = kubernetes_namespace_v1.rerank_loadtest.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["configmaps"]
    verbs      = ["get", "create", "update", "patch"]
  }

  rule {
    api_groups = ["batch"]
    resources  = ["jobs"]
    verbs      = ["get", "list", "watch", "create"]
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

  rule {
    api_groups = [""]
    resources  = ["events"]
    verbs      = ["get", "list"]
  }
}

resource "kubernetes_role_binding_v1" "rerank_loadtest_runner" {
  metadata {
    name      = "rerank-loadtest-runner"
    namespace = kubernetes_namespace_v1.rerank_loadtest.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.rerank_loadtest_runner.metadata[0].name
  }

  # GKE 인증 플러그인은 GitHub Actions의 GSA를 Kubernetes User로 전달한다.
  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = "User"
    name      = local.rerank_loadtest_runner_github_gsa_email
  }
}

# Job pod로의 inbound traffic은 필요하지 않다.
resource "kubernetes_network_policy_v1" "rerank_loadtest_ingress" {
  metadata {
    name      = "rerank-loadtest-ingress"
    namespace = kubernetes_namespace_v1.rerank_loadtest.metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress"]
  }
}

# deny-by-default egress에 DNS와 serving TCP 8000만 추가한다. Calico가 Service
# DNAT 전후 어느 시점에 정책을 평가하는지에 따라 두 serving 규칙이 필요하다.
resource "kubernetes_network_policy_v1" "rerank_loadtest_egress" {
  metadata {
    name      = "rerank-loadtest-egress"
    namespace = kubernetes_namespace_v1.rerank_loadtest.metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Egress"]

    egress {
      to {
        ip_block {
          cidr = "${data.kubernetes_service_v1.kube_dns.spec[0].cluster_ip}/32"
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

    # Calico가 Service VIP를 기준으로 평가하는 dataplane. cluster_services_cidr
    # 전체가 아니라 실제 serving Service의 ClusterIP만 허용한다.
    egress {
      to {
        ip_block {
          cidr = "${data.kubernetes_service_v1.autoresearch_serving.spec[0].cluster_ip}/32"
        }
      }

      ports {
        protocol = "TCP"
        port     = "8000"
      }
    }

    # Calico가 DNAT 이후 endpoint pod를 기준으로 평가하는 dataplane.
    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "autoresearch"
          }
        }

        pod_selector {
          match_labels = {
            "app.kubernetes.io/name" = "autoresearch-serving"
          }
        }
      }

      ports {
        protocol = "TCP"
        port     = "8000"
      }
    }
  }

  lifecycle {
    precondition {
      condition = (
        try(data.kubernetes_service_v1.autoresearch_serving.spec[0].type, "") == "ClusterIP" &&
        try(data.kubernetes_service_v1.autoresearch_serving.spec[0].cluster_ip, "") != "" &&
        try(data.kubernetes_service_v1.autoresearch_serving.spec[0].cluster_ip, "") != "None" &&
        try(data.kubernetes_service_v1.kube_dns.spec[0].type, "") == "ClusterIP" &&
        try(data.kubernetes_service_v1.kube_dns.spec[0].cluster_ip, "") != "" &&
        try(data.kubernetes_service_v1.kube_dns.spec[0].cluster_ip, "") != "None"
      )
      error_message = "autoresearch-serving and kube-dns must be existing ClusterIP Services before the loadtest egress policy can be applied."
    }
  }
}

# Prometheus는 GitHub Actions의 snapshot-reader GSA가 Kubernetes Service proxy
# endpoint로 읽는다. resource_names로 kube-prometheus-stack Prometheus Service
# 하나만 허용하고, pods/exec나 Prometheus 파드 직접 조회는 허용하지 않는다.
resource "kubernetes_role_v1" "rerank_loadtest_prometheus_snapshot_reader" {
  metadata {
    name      = "rerank-loadtest-prometheus-snapshot-reader"
    namespace = "monitoring"
  }

  rule {
    api_groups     = [""]
    resources      = ["services/proxy"]
    resource_names = ["kube-prometheus-stack-prometheus"]
    verbs          = ["get"]
  }
}

resource "kubernetes_role_binding_v1" "rerank_loadtest_prometheus_snapshot_reader" {
  metadata {
    name      = "rerank-loadtest-prometheus-snapshot-reader"
    namespace = "monitoring"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.rerank_loadtest_prometheus_snapshot_reader.metadata[0].name
  }

  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = "User"
    name      = local.rerank_loadtest_snapshot_reader_github_gsa_email
  }
}
