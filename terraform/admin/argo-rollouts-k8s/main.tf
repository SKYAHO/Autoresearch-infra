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

# helm_release를 코드에서 그냥 지우면 apply 시 Terraform이 helm uninstall을
# 실행해 Argo Rollouts 컨트롤러와 CRD를 삭제한다. destroy=false로 실제 release는
# 유지하고 Terraform state에서만 안전하게 제거한다.
removed {
  from = helm_release.argo_rollouts
  lifecycle {
    destroy = false
  }
}
