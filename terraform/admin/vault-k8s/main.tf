# #134 Vault dev 설치. Kubernetes API 접근과 Helm lifecycle은 운영자 전용
# 작업이라 dev root와 분리된 admin root로 관리한다(argocd-k8s와 동일 패턴).
# GCP 측 기반(KMS key, GSA, WI 바인딩)은 dev root vault.tf(#132)가 담당한다.

resource "kubernetes_namespace_v1" "vault" {
  metadata {
    name = var.vault_namespace

    labels = {
      "app.kubernetes.io/name"           = "vault"
      "app.kubernetes.io/part-of"        = "secret-management"
      "pod-security.kubernetes.io/audit" = "baseline"
      "pod-security.kubernetes.io/warn"  = "baseline"
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

# Vault namespace 네트워크 경계. Vault는 secret을 다루는 제어면이므로
# deny-by-default로 두고, enforcement(Calico, #116)에서 배운 예외를 반영한다.

resource "kubernetes_network_policy_v1" "vault_ingress" {
  metadata {
    name      = "vault-ingress"
    namespace = kubernetes_namespace_v1.vault.metadata[0].name
  }

  spec {
    pod_selector {}

    policy_types = ["Ingress"]

    # 같은 namespace 내 통신 (server/raft 8200/8201)
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

    # kubectl port-forward 경로: 트래픽이 노드(dev subnet IP)에서 출발하므로
    # 노드 대역에서 vault server 컨테이너 포트(8200)로의 ingress를 허용한다.
    # argocd-k8s의 #116 규칙과 동일 패턴.
    ingress {
      from {
        ip_block {
          cidr = var.ui_ingress_source_cidr
        }
      }

      ports {
        port     = "8200"
        protocol = "TCP"
      }
    }
  }
}

resource "kubernetes_network_policy_v1" "vault_egress" {
  metadata {
    name      = "vault-egress"
    namespace = kubernetes_namespace_v1.vault.metadata[0].name
  }

  spec {
    pod_selector {}

    policy_types = ["Egress"]

    # 같은 namespace 내 통신 (raft cluster 8201 등)
    egress {
      to {
        pod_selector {}
      }
    }

    # #122 service VIP 경유 트래픽. 이 클러스터의 Calico는 egress를 DNAT
    # 이전(service VIP 기준)에 평가하므로 selector가 VIP에 매칭되지 않는다.
    # kube-dns(53)와 kubernetes.default(443, service_registration이 사용)
    # VIP를 services CIDR ipBlock으로 허용한다(#138에서 443 추가 — 이전에는
    # 0.0.0.0/0:443이 커버했다).
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

    # DNS (kube-dns) — post-DNAT 평가 dataplane 대비 유지
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

    # GKE metadata 경로. auto-unseal(gcpckms)의 WI 토큰 교환이 의존한다.
    # Dataplane V2용 169.254.169.254:80과 GKE Standard+Calico의 link-local
    # proxy 987/988을 모두 허용한다(#126/#127 교훈).
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

    # Cloud KMS 등 Google API. dev root의 private googleapis DNS zone(#138)이
    # *.googleapis.com을 private.googleapis.com 고정 VIP로 유도하므로
    # 0.0.0.0/0 대신 해당 대역만 허용한다(Google 문서화된 고정 대역).
    # Kubernetes API는 위 services CIDR 443 규칙이 커버한다.
    egress {
      to {
        ip_block {
          cidr = "199.36.153.8/30"
        }
      }

      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }
}

# #134 Vault 최소 설치. UI/API는 ClusterIP + kubectl port-forward 내부 접근만
# 허용한다. TLS는 1단계 비활성(클러스터 내부 + port-forward 한정) — 실 secret
# 이관 전 TLS 활성화가 선행돼야 한다(설계 문서/README 참조).
# init 출력물(root token, recovery keys)은 Terraform/Git에 저장하지 않는다
# (절차는 docs/VAULT_OPERATIONS_RUNBOOK.md).
resource "helm_release" "vault" {
  name       = var.vault_release_name
  repository = "https://helm.releases.hashicorp.com"
  chart      = "vault"
  version    = var.vault_chart_version
  namespace  = kubernetes_namespace_v1.vault.metadata[0].name

  atomic           = true
  cleanup_on_fail  = true
  create_namespace = false
  timeout          = 600

  values = [
    file("${path.module}/${var.vault_values_file_path}")
  ]
}
