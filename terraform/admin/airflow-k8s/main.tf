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

# GitHub Actions deployer는 Helm chart가 소유하는 리소스에 대해 airflow
# namespace 안에서만 admin 권한을 가진다. cluster-wide 권한은 부여하지 않는다.
resource "kubernetes_role_binding_v1" "airflow_deployer_admin" {
  metadata {
    name      = "airflow-deployer-admin"
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
    name      = local.airflow_deployer_service_account_email
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
    # webserver 8080으로 오는 트래픽만 추가 허용. 전제: Service에
    # externalTrafficPolicy=Local(Helm values, 문서 참조) — 이때만 internal
    # LB(pass-through)가 클라이언트 source IP를 보존한다. 기본값(Cluster)이면
    # 노드 IP로 SNAT되어 이 CIDR 제한이 사실상 노드 전체 허용이 된다.
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

    # #116 같은 namespace 내 pod 간 통신(webserver/scheduler → in-cluster
    # PostgreSQL 5432, redis 6379 등). enforcement(Calico) 활성화 시 이 허용이
    # 없으면 Airflow 내부 통신이 차단된다.
    egress {
      to {
        pod_selector {}
      }
    }

    # #122 service VIP 경유 트래픽. 이 클러스터의 Calico는 egress를 DNAT
    # 이전(service VIP 기준)에 평가하므로 selector가 VIP에 매칭되지 않는다.
    # kube-dns(53)와 in-cluster PostgreSQL(5432) VIP를 services CIDR
    # ipBlock으로 허용한다. 아래 selector 기반 규칙들은 post-DNAT 평가
    # dataplane으로 바뀌는 경우를 대비해 유지한다.
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
        port     = "5432"
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

    # #234 MLflow tracking server(mlflow 네임스페이스, ClusterIP
    # mlflow.mlflow:5000). Calico가 egress를 DNAT 이전(service VIP 기준)에
    # 평가하므로 namespace_selector가 VIP에 매칭되지 않는다 — 위 kube-dns/
    # PostgreSQL과 같은 이유로 services CIDR ipBlock을 사용한다.
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

    # DNAT 후 평가하는 dataplane용 mlflow namespace selector 규칙(방어적 유지,
    # 위 kube-dns 패턴과 동일).
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

    # Existing GKE metadata endpoint allowance used by Dataplane V2.
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

    # GKE Standard with Calico uses the link-local metadata proxy ports for
    # Workload Identity Federation token exchange.
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

    # Google APIs and other HTTPS endpoints needed by providers/connectors.
    # #138 검토: OpenRouter 등 외부 API와 Cloud Run proxy(run.app) 의존으로
    # 0.0.0.0/0을 유지한다(vault처럼 private.googleapis VIP로 축소 불가).
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
