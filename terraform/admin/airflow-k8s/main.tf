# Airflow Kubernetes boundary is separated from terraform/envs/dev because the
# dev CI plan runner is not in GKE master_authorized_networks. Run this root
# only from an operator environment that can reach the GKE API server.

resource "kubernetes_namespace_v1" "airflow" {
  metadata {
    name = var.airflow_k8s_namespace
    labels = {
      "app.kubernetes.io/name" = "airflow"
    }
  }
}

resource "kubernetes_service_account_v1" "airflow" {
  metadata {
    name      = var.airflow_k8s_service_account
    namespace = var.airflow_k8s_namespace
    annotations = {
      "iam.gke.io/gcp-service-account" = local.airflow_gcp_service_account_email
    }
  }

  depends_on = [kubernetes_namespace_v1.airflow]
}

resource "kubernetes_role_v1" "airflow_components" {
  metadata {
    name      = "airflow-components"
    namespace = var.airflow_k8s_namespace
  }

  rule {
    api_groups = [""]
    resources  = ["pods", "configmaps", "secrets", "services"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  rule {
    api_groups = ["apps"]
    resources  = ["deployments", "statefulsets"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  rule {
    api_groups = ["batch"]
    resources  = ["jobs", "cronjobs"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
}

resource "kubernetes_role_binding_v1" "airflow_sa" {
  metadata {
    name      = "airflow-sa"
    namespace = var.airflow_k8s_namespace
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.airflow_components.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.airflow.metadata[0].name
    namespace = var.airflow_k8s_namespace
  }

  depends_on = [kubernetes_namespace_v1.airflow]
}

resource "kubernetes_role_binding_v1" "installer_admin" {
  for_each = var.installer_user_emails

  metadata {
    name      = "airflow-installer-${replace(lower(each.value), "/[^a-z0-9-]/", "-")}"
    namespace = var.airflow_k8s_namespace
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "admin"
  }

  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = "User"
    name      = each.value
  }

  depends_on = [kubernetes_namespace_v1.airflow]
}

resource "kubernetes_resource_quota_v1" "airflow" {
  metadata {
    name      = "airflow-quota"
    namespace = var.airflow_k8s_namespace
  }

  spec {
    hard = {
      "requests.cpu"           = "4"
      "requests.memory"        = "8Gi"
      "pods"                   = "20"
      "persistentvolumeclaims" = "4"
    }
  }

  depends_on = [kubernetes_namespace_v1.airflow]
}

resource "kubernetes_limit_range_v1" "airflow" {
  metadata {
    name      = "airflow-limits"
    namespace = var.airflow_k8s_namespace
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
    }
  }

  depends_on = [kubernetes_namespace_v1.airflow]
}

resource "kubernetes_network_policy_v1" "airflow_ingress" {
  metadata {
    name      = "airflow-ingress"
    namespace = var.airflow_k8s_namespace
  }

  spec {
    pod_selector {}

    policy_types = ["Ingress"]

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

    # #48 Airflow UI 내부 노출: dev subnet(Bastion 등 VPC 내부)에서
    # webserver 8080으로 오는 트래픽만 추가 허용. internal LB(pass-through)는
    # 클라이언트 source IP를 보존하므로 subnet CIDR 기준으로 제한한다.
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

  depends_on = [kubernetes_namespace_v1.airflow]
}

resource "kubernetes_network_policy_v1" "airflow_egress" {
  metadata {
    name      = "airflow-egress"
    namespace = var.airflow_k8s_namespace
  }

  spec {
    pod_selector {}

    policy_types = ["Egress"]

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

    # Cloud SQL (private services CIDR, PostgreSQL)
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

    # GKE metadata server for Workload Identity token exchange.
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

    # Google APIs and other HTTPS endpoints needed by providers/connectors.
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

  depends_on = [kubernetes_namespace_v1.airflow]
}
