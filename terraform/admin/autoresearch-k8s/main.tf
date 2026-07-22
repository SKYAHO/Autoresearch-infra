# Autoresearch application Kubernetes boundary is separated from
# terraform/envs/dev because it requires direct GKE API access and a separate state.

resource "kubernetes_namespace_v1" "autoresearch" {
  metadata {
    name = var.app_k8s_namespace
    labels = {
      "app.kubernetes.io/name" = "autoresearch"
    }
  }
}

resource "kubernetes_service_account_v1" "app" {
  metadata {
    name      = var.app_k8s_service_account
    namespace = kubernetes_namespace_v1.autoresearch.metadata[0].name
    annotations = {
      "iam.gke.io/gcp-service-account" = local.app_gcp_service_account_email
    }
  }
}

resource "kubernetes_network_policy_v1" "app_egress" {
  metadata {
    name      = "autoresearch-egress"
    namespace = kubernetes_namespace_v1.autoresearch.metadata[0].name
  }

  spec {
    pod_selector {}

    policy_types = ["Egress"]

    # Application components in the same namespace may communicate with each other.
    egress {
      to {
        pod_selector {}
      }
    }

    # Calico evaluates service traffic before DNAT in this cluster, so DNS service
    # VIP traffic must be allowed against the services secondary CIDR.
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

    # DNS selector rule is retained for dataplanes that evaluate after DNAT.
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

    # Existing Private Service Access range: Cloud SQL PostgreSQL only.
    egress {
      to {
        ip_block {
          cidr = var.private_services_cidr
        }
      }

      ports {
        protocol = "TCP"
        port     = "5432"
      }
    }

    # Redis Cluster PSC discovery endpoint and data node topology ports.
    egress {
      to {
        ip_block {
          cidr = var.redis_psc_subnet_cidr
        }
      }

      ports {
        protocol = "TCP"
        port     = tostring(var.redis_discovery_port)
      }

      ports {
        protocol = "TCP"
        port     = tostring(var.redis_node_port_start)
        end_port = var.redis_node_port_end
      }
    }

    # GKE metadata server endpoints required for Workload Identity.
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

    # Application and Google APIs use HTTPS; no other public destination ports are allowed.
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

    # #302 MLflow tracking server: registry alias 해석과 모델 artifact 다운로드.
    # artifact는 mlflow-artifacts:/ 스킴이라 서버를 경유하므로 GCS 직접 egress는
    # 필요 없다. DNS 규칙과 같은 이중 패턴을 쓴다 — Calico가 service 트래픽을 DNAT
    # 이전에 평가하므로 ClusterIP VIP는 services CIDR로 열고, DNAT 이후 평가하는
    # dataplane을 위해 namespace selector 규칙을 함께 둔다.
    egress {
      to {
        ip_block {
          cidr = var.cluster_services_cidr
        }
      }

      ports {
        protocol = "TCP"
        port     = "5000"
      }
    }

    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "mlflow"
          }
        }
      }

      ports {
        protocol = "TCP"
        port     = "5000"
      }
    }
  }

  depends_on = [kubernetes_namespace_v1.autoresearch]
}

# #252 팀원용 최소 권한. built-in ClusterRole `view`(secret 제외 read)는
# pods/portforward를 포함하지 않으므로, port-forward에 필요한 subresource create만
# 별도 namespace Role로 부여한다. exec/write/cluster-admin은 주지 않는다.
# (mlflow-k8s #236과 동일 패턴.)
resource "kubernetes_role_v1" "autoresearch_portforward" {
  metadata {
    name      = "autoresearch-portforward"
    namespace = kubernetes_namespace_v1.autoresearch.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["pods/portforward"]
    verbs      = ["create"]
  }

  depends_on = [kubernetes_namespace_v1.autoresearch]
}

# namespace 범위 read(view). ClusterRole `view`는 secret을 제외한 read라
# 앱/모델 파드 디버깅에 필요한 pods/services/logs 조회를 커버한다.
resource "kubernetes_role_binding_v1" "autoresearch_viewer" {
  for_each = var.autoresearch_viewer_user_emails

  metadata {
    name      = "autoresearch-viewer-${replace(lower(each.value), "/[^a-z0-9-]/", "-")}"
    namespace = kubernetes_namespace_v1.autoresearch.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "view"
  }

  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = "User"
    name      = each.value
  }

  depends_on = [kubernetes_namespace_v1.autoresearch]
}

# port-forward subresource create.
resource "kubernetes_role_binding_v1" "autoresearch_portforward" {
  for_each = var.autoresearch_viewer_user_emails

  metadata {
    name      = "autoresearch-portforward-${replace(lower(each.value), "/[^a-z0-9-]/", "-")}"
    namespace = kubernetes_namespace_v1.autoresearch.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.autoresearch_portforward.metadata[0].name
  }

  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = "User"
    name      = each.value
  }

  depends_on = [kubernetes_namespace_v1.autoresearch]
}

# #266 앱 저장소의 Feast·Redis GKE 검증 runbook은 파드 안에서 `feast apply`,
# materialize, 조회 스크립트를 돌리는 절차라 `kubectl exec`/`cp`가 전제다. view와
# portforward만으로는 실행할 수 없어 exec subresource만 별도 Role로 부여한다.
# 주의: exec은 파드 내부 환경변수·마운트를 볼 수 있어 view보다 강한 권한이다.
# 대상은 앱 namespace 검증 담당(viewer 목록)과 동일하게 두고, write/delete와
# cluster-admin은 여전히 부여하지 않는다.
resource "kubernetes_role_v1" "autoresearch_exec" {
  metadata {
    name      = "autoresearch-exec"
    namespace = kubernetes_namespace_v1.autoresearch.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["pods/exec"]
    verbs      = ["create"]
  }

  depends_on = [kubernetes_namespace_v1.autoresearch]
}

resource "kubernetes_role_binding_v1" "autoresearch_exec" {
  for_each = var.autoresearch_viewer_user_emails

  metadata {
    name      = "autoresearch-exec-${replace(lower(each.value), "/[^a-z0-9-]/", "-")}"
    namespace = kubernetes_namespace_v1.autoresearch.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.autoresearch_exec.metadata[0].name
  }

  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = "User"
    name      = each.value
  }

  depends_on = [kubernetes_namespace_v1.autoresearch]
}
