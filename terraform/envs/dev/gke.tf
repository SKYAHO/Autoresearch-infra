# #5 dev GKE — 서비스 계정 + Workload Identity
# 노드 SA: 클러스터 전체(AR pull, 로깅, 모니터링). app SA: pod 단위 권한(Cloud SQL, Secret).

resource "google_service_account" "gke_nodes" {
  account_id   = local.gke_node_sa_name
  display_name = "Autoresearch dev GKE node pool SA"
}

resource "google_project_iam_member" "gke_nodes_ar" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

resource "google_project_iam_member" "gke_nodes_logging" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

resource "google_project_iam_member" "gke_nodes_monitoring" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

resource "google_service_account" "gke_app" {
  account_id   = local.gke_app_sa_name
  display_name = "Autoresearch dev GKE app workload identity SA"
}

# ponytail: Cloud SQL/Secret 접근은 app pod만(WI). 노드 SA에 주지 않음(최소 권한).
resource "google_project_iam_member" "gke_app_cloudsql" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.gke_app.email}"
}

resource "google_project_iam_member" "gke_app_secret" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.gke_app.email}"
}

resource "google_service_account_iam_member" "gke_app_wi" {
  service_account_id = google_service_account.gke_app.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.gke_workload_identity_principal}"
}

# #5 dev GKE 클러스터 + 노드풀
# Standard zonal, private nodes + master authorized networks. autoscaling min1/max2.
resource "google_container_cluster" "dev" {
  name     = local.gke_cluster_name
  location = var.zone
  project  = var.project_id

  network    = google_compute_network.dev.id
  subnetwork = google_compute_subnetwork.dev.id

  remove_default_node_pool = true
  initial_node_count       = 1

  release_channel {
    channel = var.gke_release_channel
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  ip_allocation_policy {
    cluster_secondary_range_name  = local.gke_pods_range_name
    services_secondary_range_name = local.gke_services_range_name
  }

  # private nodes. 엔드포인트는 public(master_authorized_networks로 본인 IP만 허용) — 노트북 kubectl용.
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = var.gke_master_ipv4_cidr
  }

  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = toset(var.master_authorized_networks)
      content {
        cidr_block   = cidr_blocks.value
        display_name = "user"
      }
    }
  }

  deletion_protection = var.gke_deletion_protection

  depends_on = [google_compute_router_nat.dev]
}

resource "google_container_node_pool" "dev" {
  name       = local.gke_node_pool_name
  cluster    = google_container_cluster.dev.id
  location   = var.zone
  node_count = var.gke_node_count_min

  autoscaling {
    min_node_count = var.gke_node_count_min
    max_node_count = var.gke_node_count_max
  }

  node_config {
    machine_type    = var.gke_machine_type
    disk_size_gb    = var.gke_node_disk_size
    disk_type       = var.gke_node_disk_type
    service_account = google_service_account.gke_nodes.email
    tags            = [local.ssh_iap_tag]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }

  # autoscaler가 노드 수를 바꿔도 Terraform이 되돌리지 않도록.
  lifecycle {
    ignore_changes = [node_count]
  }
}
