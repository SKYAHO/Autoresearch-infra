# #346 feast apply 전용 Kubernetes 경계.
#
# `feast apply`의 online store 고아 키 정리(`full_scan_for_deletion: true`)는
# Redis(PSC, VPC 내부)에 직접 닿아야 해서 GitHub Actions 러너에서는 불가능하다.
# 실행 주체만 VPC 안 GKE Job으로 옮기고, GHA는 Job 생성·결과 판정만 한다.
#
# 앱 namespace(autoresearch)를 재사용하지 않는 이유: 그 namespace에
# `batch/jobs: create`를 주면 Job의 serviceAccountName을 `autoresearch-app`으로
# 지정해 gke_app GSA(DB 비밀번호 secret·Cloud SQL·BQ dataEditor)로 임의 컨테이너를
# 실행할 수 있다. 또 jobs create 보유 주체는 Pod spec으로 namespace 내 임의 K8s
# Secret을 마운트할 수 있어 RBAC에서 secrets를 빼는 것만으로는 막히지 않는다.
# 그래서 전용 namespace를 두고 그 안에 feast-apply KSA 하나만 둔다.

resource "kubernetes_namespace_v1" "feast_apply" {
  metadata {
    name = var.feast_apply_k8s_namespace
    labels = {
      "app.kubernetes.io/name" = "feast-apply"
    }
  }
}

resource "kubernetes_service_account_v1" "feast_apply" {
  metadata {
    name      = var.feast_apply_k8s_service_account
    namespace = kubernetes_namespace_v1.feast_apply.metadata[0].name
    annotations = {
      "iam.gke.io/gcp-service-account" = local.feast_apply_gcp_service_account_email
    }
  }
}

# GitHub Actions(feast_apply GSA)가 이 namespace에서만 Job을 다룰 수 있게 한다.
# - watch 필수: `kubectl wait`가 list+watch로 동작해 누락 시 403이 된다.
# - update/patch는 주지 않는다. Job spec은 대부분 immutable이라 `kubectl apply`로
#   갱신이 안 되고, 워크플로우는 "delete 후 create" 절차를 전제로 한다.
# - pods/pods-log는 실패 원인 확인용 read만. exec·cluster-admin은 부여하지 않는다.
resource "kubernetes_role_v1" "feast_apply_job_runner" {
  metadata {
    name      = "feast-apply-job-runner"
    namespace = kubernetes_namespace_v1.feast_apply.metadata[0].name
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

  depends_on = [kubernetes_namespace_v1.feast_apply]
}

# subject는 GHA가 WIF로 가장하는 GSA. GKE는 GSA 이메일을 K8s User로 매핑한다
# (airflow-k8s의 airflow_deployer_admin과 동일 패턴).
resource "kubernetes_role_binding_v1" "feast_apply_job_runner" {
  metadata {
    name      = "feast-apply-job-runner"
    namespace = kubernetes_namespace_v1.feast_apply.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.feast_apply_job_runner.metadata[0].name
  }

  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = "User"
    name      = local.feast_apply_gcp_service_account_email
  }

  depends_on = [kubernetes_namespace_v1.feast_apply]
}

# 앱 namespace의 autoresearch-egress는 pod_selector {}로 그 namespace에만
# 적용되므로 전용 namespace에는 걸리지 않는다. feast apply에 필요한 범위만
# 이식한다. Cloud SQL(private_services_cidr:5432)은 feast apply가 쓰지 않아
# 제외한다.
resource "kubernetes_network_policy_v1" "feast_apply_egress" {
  metadata {
    name      = "feast-apply-egress"
    namespace = kubernetes_namespace_v1.feast_apply.metadata[0].name
  }

  spec {
    pod_selector {}

    policy_types = ["Egress"]

    # Calico가 service 트래픽을 DNAT 이전에 평가하므로 DNS service VIP는
    # services CIDR로 열고, DNAT 이후 평가하는 dataplane을 위해 namespace
    # selector 규칙을 함께 둔다(앱 namespace와 동일한 이중 패턴).
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

    # Redis Cluster PSC discovery endpoint와 data node topology 포트.
    # 클라이언트가 CLUSTER SLOTS로 받은 노드 주소에 직접 접속하므로 discovery
    # 포트만으로는 부족하다.
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

    # Secret Manager(Redis CA)·GCS(registry)·BigQuery(source validation) 호출용.
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

  depends_on = [kubernetes_namespace_v1.feast_apply]
}
