# #5 dev GKE — 서비스 계정 + Workload Identity
# 노드 SA: AR pull (dev 리포만), 로깅, 모니터링. app SA: pod 단위 권한(Cloud SQL, Secret).

resource "google_service_account" "gke_nodes" {
  account_id   = local.gke_node_sa_name
  display_name = "Autoresearch dev GKE node pool SA"
}

# ponytail: dev 리포 수준으로 축소(#26). 프로젝트 전체 AR 접근 불필요 — 새 리포 추가 시에만 바인딩 확장.
resource "google_artifact_registry_repository_iam_member" "gke_nodes_ar" {
  repository = google_artifact_registry_repository.dev.id
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.gke_nodes.email}"
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

# ponytail: Cloud SQL 접근은 app pod만(WI). 노드 SA에 주지 않음(최소 권한).
# Secret 접근 권한은 secret_manager.tf 에서 db_app_password secret 리소스에만 부여(최소 권한).
resource "google_project_iam_member" "gke_app_cloudsql" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.gke_app.email}"
}

resource "google_service_account_iam_member" "gke_app_wi" {
  service_account_id = google_service_account.gke_app.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.gke_workload_identity_principal}"

  depends_on = [google_container_cluster.dev]
}

# #5 dev GKE 클러스터 + 노드풀
# Standard zonal, private nodes. kubectl 기본 경로는 DNS 엔드포인트(#45),
# master authorized networks(IP 엔드포인트)는 예비. autoscaling min1/max2.
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

  # #116 NetworkPolicy enforcement(Calico). admin root들의 NetworkPolicy가
  # 실제로 강제되도록 켠다. 활성화 apply 시 노드풀이 롤링 재생성된다.
  # 보안 경계이므로 변수 토글 없이 상시 활성으로 둔다.
  network_policy {
    enabled  = true
    provider = "CALICO"
  }

  addons_config {
    network_policy_config {
      disabled = false
    }
  }

  # private nodes. 마스터 접근 기본 경로는 DNS 엔드포인트(#45, IAM 검증)이고,
  # public IP 엔드포인트 + master_authorized_networks는 예비 경로로 병행 유지.
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

  # #45 DNS 기반 컨트롤 플레인 엔드포인트. Google 프런트엔드에서
  # IAM(container.clusters.connect)으로 검증되므로 팀원은 IP 등록 없이
  # 구글 계정만으로 kubectl 접근 가능. 기존 IP 엔드포인트와
  # master_authorized_networks는 전환기 동안 병행 유지한다.
  control_plane_endpoints_config {
    dns_endpoint_config {
      allow_external_traffic = true
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

resource "google_container_node_pool" "airflow" {
  name       = var.airflow_gke_node_pool_name
  cluster    = google_container_cluster.dev.name
  location   = var.zone
  node_count = var.airflow_gke_node_count_min

  autoscaling {
    min_node_count = var.airflow_gke_node_count_min
    max_node_count = var.airflow_gke_node_count_max
  }

  node_config {
    machine_type    = var.airflow_gke_machine_type
    disk_size_gb    = var.airflow_gke_node_disk_size
    disk_type       = var.airflow_gke_node_disk_type
    service_account = google_service_account.gke_nodes.email

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }

  lifecycle {
    ignore_changes = [node_count]
  }
}

# #173 KPO batch 전용 Spot pool (#105 후속 ②). KPO는 재시도 내성이 있어
# Spot 중단을 흡수한다(재시도는 앱 저장소 KPO retry 설정 소관).
# - min 0: 평시 노드 0대(비용 0). toleration+nodeSelector를 가진 KPO pod가
#   Pending이 되면 CA가 scale-from-zero로 노드를 만든다.
# - taint: 일반 워크로드가 Spot에 앉는 것을 차단(#105 기준 — 전용 pool은
#   taint 필수). DaemonSet(filebeat/node-exporter)은 toleration을 부여했다.
# - 부트 디스크 pd-standard: SSD_TOTAL_GB quota 여유가 없다(#98 교훈).
resource "google_container_node_pool" "batch_spot" {
  name       = var.batch_spot_gke_node_pool_name
  cluster    = google_container_cluster.dev.name
  location   = var.zone
  node_count = 0

  autoscaling {
    min_node_count = 0
    max_node_count = var.batch_spot_gke_node_count_max
  }

  node_config {
    machine_type    = var.batch_spot_gke_machine_type
    disk_size_gb    = 30
    disk_type       = "pd-standard"
    spot            = true
    service_account = google_service_account.gke_nodes.email

    taint {
      key    = "workload"
      value  = "batch-spot"
      effect = "NO_SCHEDULE"
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }

  lifecycle {
    ignore_changes = [node_count]
  }
}
