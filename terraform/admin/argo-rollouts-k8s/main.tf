# #88 Argo Rollouts controller 설치. Rollout CR 실행(점진 배포)을 담당하는
# 플랫폼 컴포넌트로, argocd-k8s/vault-k8s와 동일하게 별도 admin root로
# 관리한다. 적용 범위·책임 경계는 #87 설계를 따른다:
# docs/superpowers/specs/2026-07-13-argo-rollouts-scope-design.md

resource "kubernetes_namespace_v1" "argo_rollouts" {
  metadata {
    name = var.rollouts_namespace

    labels = {
      "app.kubernetes.io/name"           = "argo-rollouts"
      "app.kubernetes.io/part-of"        = "gitops"
      "pod-security.kubernetes.io/audit" = "baseline"
      "pod-security.kubernetes.io/warn"  = "baseline"
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "kubernetes_network_policy_v1" "rollouts_ingress" {
  metadata {
    name      = "argo-rollouts-ingress"
    namespace = kubernetes_namespace_v1.argo_rollouts.metadata[0].name
  }

  spec {
    pod_selector {}

    policy_types = ["Ingress"]

    # 같은 namespace (샘플 rollout pod 등 #89)
    ingress {
      from {
        pod_selector {}
      }
    }

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "kube-system"
          }
        }
      }
    }
  }
}

# controller egress는 DNS와 Kubernetes API만 필요하다(GCP API 미사용,
# Workload Identity 불필요 — metadata/googleapis 규칙 없음).
resource "kubernetes_network_policy_v1" "rollouts_egress" {
  metadata {
    name      = "argo-rollouts-egress"
    namespace = kubernetes_namespace_v1.argo_rollouts.metadata[0].name
  }

  spec {
    pod_selector {}

    policy_types = ["Egress"]

    egress {
      to {
        pod_selector {}
      }
    }

    # #122 pre-DNAT(VIP) 평가: kube-dns(53), kubernetes.default(443)
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

      ports {
        protocol = "TCP"
        port     = "443"
      }
    }

    # DNS post-DNAT dataplane 대비 유지 (#122)
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

    # K8s API post-DNAT 목적지(master) 대비 (#138 패턴)
    egress {
      to {
        ip_block {
          cidr = var.cluster_master_cidr
        }
      }

      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }
}

# #88 Argo Rollouts 최소 설치. dashboard는 설치하지 않고 kubectl plugin으로
# 운영한다(#90 runbook). chart가 만드는 ClusterRole은 Rollout/ReplicaSet 등
# 전환 실행에 필요한 리소스 범위로 한정된 upstream 기본값을 사용한다.
resource "helm_release" "argo_rollouts" {
  name       = var.rollouts_release_name
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-rollouts"
  version    = var.rollouts_chart_version
  namespace  = kubernetes_namespace_v1.argo_rollouts.metadata[0].name

  atomic           = true
  cleanup_on_fail  = true
  create_namespace = false
  timeout          = 600

  values = [
    file("${path.module}/${var.rollouts_values_file_path}")
  ]
}
