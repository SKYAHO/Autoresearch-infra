# MLflow tracking server의 Kubernetes 경계는 GKE API 직접 접근이 필요해
# terraform/envs/dev와 분리한다(별도 state). #91 설계, #94 배포.
# chart(앱) 배포는 ArgoCD(deploy/mlflow)가 맡고, 이 root는 namespace/KSA/
# NetworkPolicy(플랫폼 경계)만 소유한다.

resource "kubernetes_namespace_v1" "mlflow" {
  metadata {
    name = var.mlflow_k8s_namespace
    labels = {
      "app.kubernetes.io/name" = "mlflow"
    }
  }
}

# Workload Identity: 이 KSA가 MLflow GCP SA를 가장한다(GCS artifact·Cloud SQL).
resource "kubernetes_service_account_v1" "mlflow" {
  metadata {
    name      = var.mlflow_k8s_service_account
    namespace = kubernetes_namespace_v1.mlflow.metadata[0].name
    annotations = {
      "iam.gke.io/gcp-service-account" = local.mlflow_gcp_service_account_email
    }
  }
}

# deny-by-default egress + 최소 화이트리스트. Redis는 대상 아님(autoresearch와 차이).
resource "kubernetes_network_policy_v1" "mlflow_egress" {
  metadata {
    name      = "mlflow-egress"
    namespace = kubernetes_namespace_v1.mlflow.metadata[0].name
  }

  spec {
    pod_selector {}

    policy_types = ["Egress"]

    # 같은 namespace 내 통신.
    egress {
      to {
        pod_selector {}
      }
    }

    # DNS: Calico가 DNAT 전에 평가하므로 services CIDR로 VIP 트래픽 허용.
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

    # DNAT 후 평가하는 dataplane용 kube-system selector 규칙.
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

    # Cloud SQL PostgreSQL(private IP, PSA range)만.
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

    # Workload Identity metadata 엔드포인트.
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

    # GCS·Google API는 HTTPS. 그 외 공개 목적지 포트는 허용하지 않는다.
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

  depends_on = [kubernetes_namespace_v1.mlflow]
}

# #236 Model Training 담당자용 최소 권한. built-in ClusterRole `view`(secret 제외
# read)는 pods/portforward를 포함하지 않으므로, port-forward에 필요한 subresource
# create만 별도 namespace Role로 부여한다. exec/write/cluster-admin은 주지 않는다.
resource "kubernetes_role_v1" "mlflow_portforward" {
  metadata {
    name      = "mlflow-portforward"
    namespace = kubernetes_namespace_v1.mlflow.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["pods/portforward"]
    verbs      = ["create"]
  }

  depends_on = [kubernetes_namespace_v1.mlflow]
}

# namespace 범위 read(view). ClusterRole `view`는 secret을 제외한 read라
# MLflow UI 검증에 필요한 pods/services 조회를 커버한다.
resource "kubernetes_role_binding_v1" "mlflow_viewer" {
  for_each = var.mlflow_viewer_user_emails

  metadata {
    name      = "mlflow-viewer-${replace(lower(each.value), "/[^a-z0-9-]/", "-")}"
    namespace = kubernetes_namespace_v1.mlflow.metadata[0].name
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

  depends_on = [kubernetes_namespace_v1.mlflow]
}

# port-forward subresource create.
resource "kubernetes_role_binding_v1" "mlflow_portforward" {
  for_each = var.mlflow_viewer_user_emails

  metadata {
    name      = "mlflow-portforward-${replace(lower(each.value), "/[^a-z0-9-]/", "-")}"
    namespace = kubernetes_namespace_v1.mlflow.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.mlflow_portforward.metadata[0].name
  }

  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = "User"
    name      = each.value
  }

  depends_on = [kubernetes_namespace_v1.mlflow]
}
