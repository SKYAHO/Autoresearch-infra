# 셀프 호스티드 러너(ARC)의 Kubernetes 경계는 GKE API 직접 접근이 필요해
# terraform/envs/dev와 분리한다(별도 state). #533 설계.
# ARC 컨트롤러/러너 chart 자체는 ArgoCD(deploy/actions-runner-controller,
# deploy/actions-runner-scale-set)가 배포하고, 이 root는 namespace/KSA/
# NetworkPolicy/quota(플랫폼 경계)만 소유한다.
#
# 이 namespace는 ARC가 관리하는 임시 러너 Pod 템플릿을 이 root가 직접
# 통제하지 못하므로, 검증 전에는 restricted가 아닌 baseline PSA를 쓴다
# (experiment_jobs.tf의 restricted와 의도적으로 다름 — feast apply 이관 등
# 후속 단계에서 실제 Pod spec을 관찰한 뒤 강화 여부를 재검토한다).
resource "kubernetes_namespace_v1" "actions_runner" {
  metadata {
    name = var.actions_runner_namespace
    labels = {
      "app.kubernetes.io/name"             = "actions-runner-controller"
      "app.kubernetes.io/part-of"          = "auto-research"
      "pod-security.kubernetes.io/enforce" = "baseline"
      "pod-security.kubernetes.io/audit"   = "baseline"
      "pod-security.kubernetes.io/warn"    = "baseline"
    }
  }
}

# ARC 컨트롤러 매니저는 자신의 CRD(AutoscalingRunnerSet 등, cluster-scoped)를
# watch하고 러너 Pod/Secret/RoleBinding을 생성해야 하므로 Kubernetes API
# token 마운트가 실제로 필요하다 — 이 root의 "automount=false 기본" 원칙에
# 대한 의도적 예외(Kubernetes 기본값 유지).
resource "kubernetes_service_account_v1" "actions_runner_controller" {
  metadata {
    name      = var.actions_runner_controller_ksa
    namespace = kubernetes_namespace_v1.actions_runner.metadata[0].name
    annotations = {
      "iam.gke.io/gcp-service-account" = local.actions_runner_controller_gcp_service_account_email
    }
  }
}

# 러너(listener/ephemeral runner) Pod 신원. GCP API를 직접 호출하지 않으므로
# GSA를 공유하지 않고 WI annotation도 붙이지 않는다 — 표준 관례대로 automount만
# 끈다. PoC 워크플로우가 이 KSA로 실행된다.
resource "kubernetes_service_account_v1" "actions_runner_listener" {
  metadata {
    name      = var.actions_runner_listener_ksa
    namespace = kubernetes_namespace_v1.actions_runner.metadata[0].name
  }

  automount_service_account_token = false
}

# 러너 Pod는 checkout·build tooling으로 experiment Job보다 무거우므로 여유를
# 둔다. scale-set chart의 maxRunners와 짝(pair)을 이룬다 — 값 변경 시 함께
# 바꾼다(variables.tf actions_runner_max_pods 주석 참고).
resource "kubernetes_resource_quota_v1" "actions_runner" {
  metadata {
    name      = "actions-runner-quota"
    namespace = kubernetes_namespace_v1.actions_runner.metadata[0].name
  }

  spec {
    hard = {
      "pods"            = tostring(var.actions_runner_max_pods)
      "requests.cpu"    = "4"
      "requests.memory" = "8Gi"
      "limits.cpu"      = "4"
      "limits.memory"   = "8Gi"
    }
  }

  depends_on = [kubernetes_namespace_v1.actions_runner]
}

resource "kubernetes_limit_range_v1" "actions_runner" {
  metadata {
    name      = "actions-runner-limits"
    namespace = kubernetes_namespace_v1.actions_runner.metadata[0].name
  }

  spec {
    limit {
      type = "Container"
      default = {
        cpu    = "1"
        memory = "2Gi"
      }
      default_request = {
        cpu    = "500m"
        memory = "1Gi"
      }
      max = {
        cpu    = "2"
        memory = "4Gi"
      }
    }
  }

  depends_on = [kubernetes_namespace_v1.actions_runner]
}

# 이 namespace에는 inbound traffic이 필요 없다(GitHub이 러너로 접속하지 않고,
# 러너가 GitHub의 Actions 서비스로 outbound polling한다).
resource "kubernetes_network_policy_v1" "actions_runner_ingress" {
  metadata {
    name      = "actions-runner-ingress"
    namespace = kubernetes_namespace_v1.actions_runner.metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress"]
  }
}

# 기본 egress를 차단하고 experiment_jobs.tf 4규칙(DNS, GKE metadata, WI
# metadata, PGA)을 재사용한 뒤, 이 namespace 전용 2규칙을 더한다:
# - cluster_services_cidr:443 — PoC 워크플로우의 K8s API 서버(kubernetes.default.svc)
#   접근 검증용. GitHub-hosted 러너에서는 도달 불가능해 VPC 내부망 접근의
#   증명이 된다.
# - 0.0.0.0/0:443 — GitHub Actions 서비스(러너 등록·job polling)는 IP 대역이
#   넓고 자주 바뀌어 고정 CIDR allowlist 관례를 적용할 수 없다. 포트를 443만
#   허용하는 이름 있는 예외로 남긴다. GitHub IP allowlist로 좁히는 강화는
#   범위 밖(#533 설계 문서 참고).
resource "kubernetes_network_policy_v1" "actions_runner_egress" {
  metadata {
    name      = "actions-runner-egress"
    namespace = kubernetes_namespace_v1.actions_runner.metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Egress"]

    # 같은 namespace 내 통신(컨트롤러 ↔ 러너).
    egress {
      to {
        pod_selector {}
      }
    }

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

    # PoC: K8s API 서버(in-cluster only) 접근 검증.
    egress {
      to {
        ip_block {
          cidr = var.cluster_services_cidr
        }
      }

      ports {
        protocol = "TCP"
        port     = "443"
      }
    }

    # GitHub Actions 서비스 연결(러너 등록/job polling). 이름 있는 예외 — 위 주석 참고.
    egress {
      to {
        ip_block {
          cidr = "0.0.0.0/0"
        }
      }

      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }

  depends_on = [kubernetes_namespace_v1.actions_runner]
}
