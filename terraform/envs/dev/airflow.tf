# #32 Airflow 운영 인프라 경계
# K8s namespace/RBAC + GCP SA(WI) + Cloud SQL DB + GCS 버킷. Airflow Helm values 자체는 앱 저장소 범위.

# --- GCP 서비스 계정 + Workload Identity ---

resource "google_service_account" "airflow" {
  account_id   = local.airflow_sa_name
  display_name = "Autoresearch dev Airflow workload identity SA"
}

resource "google_service_account_iam_member" "airflow_wi" {
  service_account_id = google_service_account.airflow.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.airflow_workload_identity_principal}"

  depends_on = [google_container_cluster.dev]
}

# --- GCP IAM (project-level) ---

resource "google_project_iam_member" "airflow_cloudsql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.airflow.email}"
}

resource "google_project_iam_member" "airflow_bigquery_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.airflow.email}"
}

# --- Cloud SQL metadata DB ---

resource "google_sql_database" "airflow" {
  name     = "airflow"
  instance = google_sql_database_instance.dev.name
}

# --- GCS 버킷 (DAG 버전관리, 로그 영속화) ---

resource "google_storage_bucket" "airflow_dags" {
  name                        = local.airflow_dags_bucket_name
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  versioning {
    enabled = true
  }

  soft_delete_policy {
    retention_duration_seconds = 0
  }

  labels = {
    data_class = "dags"
    purpose    = "airflow-dags"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_storage_bucket" "airflow_logs" {
  name                        = local.airflow_logs_bucket_name
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  labels = {
    data_class = "logs"
    purpose    = "airflow-logs"
  }

  lifecycle {
    prevent_destroy = true
  }
}

# --- GCS bucket IAM (airflow SA objectAdmin) ---

resource "google_storage_bucket_iam_member" "airflow_dags_admin" {
  bucket = google_storage_bucket.airflow_dags.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.airflow.email}"
}

resource "google_storage_bucket_iam_member" "airflow_logs_admin" {
  bucket = google_storage_bucket.airflow_logs.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.airflow.email}"
}

resource "google_storage_bucket_iam_member" "airflow_raw_data_admin" {
  bucket = google_storage_bucket.raw_data.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.airflow.email}"
}

resource "google_storage_bucket_iam_member" "airflow_feast_registry_admin" {
  bucket = google_storage_bucket.feast_registry.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.airflow.email}"
}

resource "google_storage_bucket_iam_member" "airflow_feast_staging_admin" {
  bucket = google_storage_bucket.feast_staging.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.airflow.email}"
}

# --- BigQuery dataset IAM ---

resource "google_bigquery_dataset_iam_member" "airflow_feast_data_editor" {
  dataset_id = google_bigquery_dataset.feast_offline_store.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.airflow.email}"
}

# --- Kubernetes namespace + service account ---

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
      "iam.gkeusercontent.com/gcp-service-account" = google_service_account.airflow.email
    }
  }

  depends_on = [kubernetes_namespace_v1.airflow]
}

# --- Kubernetes RBAC (Airflow 구성요소용 namespace-scoped Role) ---

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

# --- Kubernetes RBAC (설치 담당자 admin 권한, for_each) ---

# ponytail: dev에서 설치 주체를 별도 variable로 분리하지 않고 gke_kubectl_user_emails(#34) 재사용.
# namespace 내 admin ClusterRole 바인딩으로 Helm 설치 경로 확보.
# TODO(#34 merge): PR #34가 main에 merge되어 gke_kubectl_user_emails variable이 생기면 아래 블록 주석 해제.
# resource "kubernetes_role_binding_v1" "installer_admin" {
#   for_each = toset(var.gke_kubectl_user_emails)
#
#   metadata {
#     # ponytail: 이메일에서 K8s name에 쓸 수 없는 문자(@,.)를 하이픈으로 치환. 고유성 보장.
#     name      = "airflow-installer-${replace(each.key, "/[^a-z0-9]/", "-")}"
#     namespace = var.airflow_k8s_namespace
#   }
#
#   role_ref {
#     api_group = "rbac.authorization.k8s.io"
#     kind      = "ClusterRole"
#     name      = "admin"
#   }
#
#   subject {
#     kind      = "User"
#     name      = each.key
#     api_group = "rbac.authorization.k8s.io"
#   }
#
#   depends_on = [kubernetes_namespace_v1.airflow]
# }

# --- namespace 자원 경계 ---

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

# --- namespace 네트워크 격리 ---

# ponytail: allow 정책으로 deny-by-default 달성. 별도 default-deny NetworkPolicy 불필요.
# ingress: 같은 namespace pod + kube-system(예: GKE 메타데이터 에이전트)만 허용.
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
  }

  depends_on = [kubernetes_namespace_v1.airflow]
}

# egress: kube-dns(53), Cloud SQL(private_services_cidr 5432), HTTPS(443)만 허용.
# ponytail: Cloud SQL private IP는 private_services_cidr /20 전체 허용 — 단일 IP 추적 비용 > dev에서 대역 허용. 운영 시 좁히기.
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

    # Cloud SQL (private services CIDR, 5432)
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

    # HTTPS (googleapis.com 등)
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
