# ArgoCD Kubernetes boundary is separated from terraform/envs/dev because
# Kubernetes API access and future Helm lifecycle are operator-controlled actions.

resource "kubernetes_namespace_v1" "argocd" {
  metadata {
    name = var.argocd_namespace

    labels = {
      "app.kubernetes.io/name"           = "argocd"
      "app.kubernetes.io/part-of"        = "gitops"
      "pod-security.kubernetes.io/audit" = "baseline"
      "pod-security.kubernetes.io/warn"  = "baseline"
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

# #116 ArgoCD namespace 네트워크 경계. ClusterIP는 클러스터 내부 접근을 막지
# 않으므로(코드 리뷰 finding), deny-by-default NetworkPolicy로 다른 namespace
# 워크로드에서 ArgoCD 제어면(server/repo-server/redis) 접근을 차단한다.
# enforcement는 dev root gke.tf의 Calico 활성화(#116)가 전제다.

resource "kubernetes_network_policy_v1" "argocd_ingress" {
  metadata {
    name      = "argocd-ingress"
    namespace = kubernetes_namespace_v1.argocd.metadata[0].name
  }

  spec {
    pod_selector {}

    policy_types = ["Ingress"]

    # ArgoCD 컴포넌트 간 통신 (server ↔ repo-server ↔ redis ↔ controller)
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

    # kubectl port-forward 경로: 트래픽이 pod가 아니라 노드(kubelet, dev subnet
    # IP)에서 출발하므로, 노드 대역에서 argocd-server 컨테이너 포트(8080)로의
    # ingress를 허용해야 UI 접근이 유지된다. airflow-k8s의 #48 규칙과 동일 패턴.
    ingress {
      from {
        ip_block {
          cidr = var.ui_ingress_source_cidr
        }
      }

      ports {
        port     = "8080"
        protocol = "TCP"
      }
    }
  }
}

resource "kubernetes_network_policy_v1" "argocd_egress" {
  metadata {
    name      = "argocd-egress"
    namespace = kubernetes_namespace_v1.argocd.metadata[0].name
  }

  spec {
    pod_selector {}

    policy_types = ["Egress"]

    # 같은 namespace 내 컴포넌트 간 통신 (redis 6379, repo-server 8081 등)
    egress {
      to {
        pod_selector {}
      }
    }

    # DNS (kube-dns)
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

    # Git/Helm repository와 Kubernetes API server 접근(HTTPS).
    # git ssh(22)는 현재 미사용이라 열지 않는다. 필요 시 별도 변경으로 추가.
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
}

# #84 ArgoCD 최소 설치. UI는 ClusterIP + kubectl port-forward 내부 접근만 허용한다.
# 초기 admin 비밀번호는 chart가 생성하는 argocd-initial-admin-secret으로 회수하고,
# 변경 후 삭제한다(절차는 README). secret payload는 Terraform/Git에 저장하지 않는다.
resource "helm_release" "argo_cd" {
  name       = var.argo_cd_release_name
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argo_cd_chart_version
  namespace  = kubernetes_namespace_v1.argocd.metadata[0].name

  atomic           = true
  cleanup_on_fail  = true
  create_namespace = false
  timeout          = 600

  values = [
    file("${path.module}/${var.argocd_values_file_path}")
  ]
}
