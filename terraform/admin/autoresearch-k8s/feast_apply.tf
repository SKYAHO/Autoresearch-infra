# #424 Feast apply 전용 Kubernetes 경계.
#
# GitHub Environment → WIF provider → GSA → namespace → KSA는 하나의 불변 튜플이다.
# 같은 GSA를 GHA(가장)와 Job Pod(WI)가 공유하되, 각 GSA에는 자기 환경 namespace의
# RoleBinding만 둬 dev GSA가 prod Job을 만들 수 없게 한다.

resource "kubernetes_namespace_v1" "feast_apply" {
  for_each = local.feast_apply_identities

  metadata {
    name = each.value.namespace
    labels = {
      "app.kubernetes.io/name"        = "feast-apply"
      "app.kubernetes.io/environment" = each.key
    }
  }
}

resource "kubernetes_service_account_v1" "feast_apply" {
  for_each = local.feast_apply_identities

  metadata {
    name      = each.value.service_account
    namespace = kubernetes_namespace_v1.feast_apply[each.key].metadata[0].name
    annotations = {
      "iam.gke.io/gcp-service-account" = each.value.gcp_service_account_email
    }
  }
}

# GHA의 각 환경 GSA는 자기 namespace에서만 Job을 다룬다.
# - watch 필수: kubectl wait가 list+watch로 동작한다.
# - update/patch는 주지 않는다. 워크플로우는 delete 후 create를 전제로 한다.
# - pods/pods-log는 실패 원인 확인용 read만. secrets, exec, cluster-wide RBAC는 없다.
resource "kubernetes_role_v1" "feast_apply_job_runner" {
  for_each = local.feast_apply_identities

  metadata {
    name      = "feast-apply-${each.key}-job-runner"
    namespace = kubernetes_namespace_v1.feast_apply[each.key].metadata[0].name
  }

  rule {
    api_groups = ["batch"]
    resources  = ["jobs"]
    verbs      = ["get", "list", "watch", "create", "delete"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods/log"]
    verbs      = ["get"]
  }
}

# subject는 GHA가 WIF로 가장하는 GSA다. GKE는 GSA 이메일을 Kubernetes User로
# 매핑하므로 annotation의 GSA와 같은 each.value만 사용해야 한다.
resource "kubernetes_role_binding_v1" "feast_apply_job_runner" {
  for_each = local.feast_apply_identities

  metadata {
    name      = "feast-apply-${each.key}-job-runner"
    namespace = kubernetes_namespace_v1.feast_apply[each.key].metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.feast_apply_job_runner[each.key].metadata[0].name
  }

  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = "User"
    name      = each.value.gcp_service_account_email
  }
}

# Feast apply Job은 아무것도 서빙하지 않으므로 ingress를 전면 차단한다.
resource "kubernetes_network_policy_v1" "feast_apply_ingress" {
  for_each = local.feast_apply_identities

  metadata {
    name      = "feast-apply-${each.key}-ingress"
    namespace = kubernetes_namespace_v1.feast_apply[each.key].metadata[0].name
  }

  spec {
    pod_selector {}

    policy_types = ["Ingress"]
  }
}

# 앱 namespace의 autoresearch-egress는 이 namespace에 적용되지 않는다. DNS, GKE
# metadata, HTTPS만 공통으로 허용하며 Redis PSC topology는 prod Job에만 허용한다.
resource "kubernetes_network_policy_v1" "feast_apply_egress" {
  for_each = local.feast_apply_identities

  metadata {
    name      = "feast-apply-${each.key}-egress"
    namespace = kubernetes_namespace_v1.feast_apply[each.key].metadata[0].name
  }

  spec {
    pod_selector {}

    policy_types = ["Egress"]

    # Calico의 DNAT 전/후 DNS 평가 모두를 위해 services CIDR와 kube-system
    # namespace selector를 함께 둔다.
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

    # Redis Cluster PSC discovery/data-node topology는 prod에만 필요하다. dev
    # NetworkPolicy에는 redis_psc_subnet_cidr나 Redis port를 렌더하지 않는다.
    dynamic "egress" {
      for_each = each.key == "prod" ? [true] : []

      content {
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
    }

    # GKE metadata server. Workload Identity 토큰 발급에 필수다.
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

    # Secret Manager, GCS, BigQuery 등 Google API 호출용이다. dev GSA에는
    # Redis/CA IAM이 없으므로 HTTPS 허용만으로 Redis 접근은 생기지 않는다.
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
