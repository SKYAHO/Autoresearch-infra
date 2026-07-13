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
  }

  depends_on = [kubernetes_namespace_v1.autoresearch]
}
