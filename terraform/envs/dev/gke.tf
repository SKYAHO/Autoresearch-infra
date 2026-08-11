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

# API와 Codex Runner는 파일 시스템·Secret Manager·Cloud SQL 권한을 공유하지
# 않는다. API만 Cloud SQL client와 전용 DB password secret accessor를 받고,
# Runner의 Secret Manager IAM은 secret_manager.tf의 OAuth bootstrap 하나뿐이다.
resource "google_service_account" "agent_orchestration_api" {
  account_id   = local.agent_orchestration_api_sa_name
  display_name = "Autoresearch dev Agent Orchestration API workload identity SA"
}

resource "google_project_iam_member" "agent_orchestration_api_cloudsql" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.agent_orchestration_api.email}"
}

resource "google_service_account_iam_member" "agent_orchestration_api_wi" {
  service_account_id = google_service_account.agent_orchestration_api.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.agent_orchestration_api_workload_identity_principal}"

  depends_on = [google_container_cluster.dev]
}

# #539 실험 브랜치 Job launcher. CronJob 한 tick이 Cloud SQL로 Experiment를 선점하고
# Kubernetes Job을 만든다. GCP 권한은 API와 같은 Cloud SQL client와 같은 DB password
# secret 하나뿐이고(secret_manager.tf), 결과 버킷·Codex OAuth secret·다른 Secret에는
# 접근하지 않는다. Job 생성 권한은 GCP IAM이 아니라 admin root의 Kubernetes RBAC가
# launcher KSA에만 부여한다.
resource "google_service_account" "agent_orchestration_launcher" {
  account_id   = local.agent_orchestration_launcher_sa_name
  display_name = "Autoresearch dev Agent Orchestration experiment launcher workload identity SA"
}

resource "google_project_iam_member" "agent_orchestration_launcher_cloudsql" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.agent_orchestration_launcher.email}"
}

resource "google_service_account_iam_member" "agent_orchestration_launcher_wi" {
  service_account_id = google_service_account.agent_orchestration_launcher.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.agent_orchestration_launcher_workload_identity_principal}"

  depends_on = [google_container_cluster.dev]
}

# #616 실험 로그 수집기. executor Pod의 컨테이너 로그를 밖에서 읽어 experiment_logs에
# 적재하는 상주 Deployment다. GCP 권한은 launcher와 같은 Cloud SQL client와 같은 DB
# password secret 하나뿐이고(secret_manager.tf), 결과 버킷·Codex OAuth secret·다른
# Secret에는 접근하지 않는다. 로그를 읽는 권한은 GCP IAM이 아니라 admin root의
# Kubernetes RBAC(experiment-job-observer)가 이 KSA에만 부여한다.
#
# launcher GSA를 재사용하지 않는다. 재사용하면 Kubernetes RBAC를 갈라 놓아도 GCP
# 층에서 두 워크로드가 같은 주체가 되어, 감사 로그에서 "Job을 만든 것"과 "로그를
# 읽은 것"을 구분할 수 없다.
resource "google_service_account" "agent_orchestration_log_collector" {
  account_id   = local.agent_orchestration_log_collector_sa_name
  display_name = "Autoresearch dev Agent Orchestration experiment log collector workload identity SA"
}

# roles/cloudsql.client는 주지 않는다. 이 워크로드는 Cloud SQL Auth Proxy도
# Python connector도 쓰지 않고 `ORCH_DB_HOST=192.168.0.3` private IP에 직접 붙어
# 비밀번호로 인증한다(`bootstrap_secrets.py`가 host를 URL에 그대로 넣고,
# `create_database_engine`은 순수 SQLAlchemy다). 그래서 그 role이 부여하는
# `cloudsql.instances.connect`/`get`은 한 번도 호출되지 않는다.
#
# API·launcher·runner는 같은 이유로 쓰지 않으면서도 이 role을 갖고 있다. 신규
# 주체까지 그 상태를 답습하지 않되, 기존 셋은 이 PR 범위 밖이라 #623으로 분리했다.
resource "google_service_account_iam_member" "agent_orchestration_log_collector_wi" {
  service_account_id = google_service_account.agent_orchestration_log_collector.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.agent_orchestration_log_collector_workload_identity_principal}"

  depends_on = [google_container_cluster.dev]
}

# #630 실험 PR 생성기. 완주한 실험의 exp 브랜치를 dev로 향하는 PR로 연다.
# GCP 권한은 DB password secret 하나뿐이다(secret_manager.tf). GitHub 접근은 GCP IAM이
# 아니라 branch-writer App의 installation token이 담당하며, 그 token은
# `pull_requests: write` 하나만 요청한다 — 앱이 코드를 push할 수 없다.
#
# roles/cloudsql.client는 주지 않는다. 수집기와 같은 이유로 private IP에 비밀번호로
# 붙어 `cloudsql.instances.connect`를 호출하지 않는다(#623 참조).
resource "google_service_account" "agent_orchestration_pull_request" {
  account_id   = local.agent_orchestration_pull_request_sa_name
  display_name = "Autoresearch dev Agent Orchestration experiment pull request opener workload identity SA"
}

resource "google_service_account_iam_member" "agent_orchestration_pull_request_wi" {
  service_account_id = google_service_account.agent_orchestration_pull_request.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.agent_orchestration_pull_request_workload_identity_principal}"

  depends_on = [google_container_cluster.dev]
}

resource "google_service_account" "agent_orchestration_runner" {
  account_id   = local.agent_orchestration_runner_sa_name
  display_name = "Autoresearch dev Agent Orchestration Codex Runner workload identity SA"
}

resource "google_service_account_iam_member" "agent_orchestration_runner_wi" {
  service_account_id = google_service_account.agent_orchestration_runner.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.agent_orchestration_runner_workload_identity_principal}"

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

  vertical_pod_autoscaling {
    enabled = true
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

# #297 재시도 내성이 없는 장시간 KPO(예: Action Log shard)용 비-Spot pool.
# batch-spot(#173)은 "KPO는 재시도 내성이 있어 Spot 중단을 흡수"라는 전제로
# 설계됐으나, Action Log shard는 graceful shutdown 미처리로 재시도 내성이 없어
# Spot 선점 시 장애가 발생했다(#297). 이 pool은 on-demand VM으로 해당 작업을
# 격리한다. 앱 쪽 toleration 이동은 Autoresearch-airflow 별도 이슈 소관.
# - min 0: 평시 노드 0대(비용 0). batch-spot과 동일 구조.
# - taint: workload=batch-od — batch-spot과 분리해 앱이 명시적으로 선택.
#   DaemonSet(filebeat/node-exporter)은 Exists/NoSchedule toleration으로 자동 커버.
# - 부트 디스크 pd-standard 100GB: 실험 workspace 최악 상한 5 × 8Gi와
#   이미지·로그·kubelet eviction headroom을 함께 수용한다(#98, #624).
resource "google_container_node_pool" "batch_od" {
  name       = var.batch_od_gke_node_pool_name
  cluster    = google_container_cluster.dev.name
  location   = var.zone
  node_count = 0

  autoscaling {
    min_node_count = 0
    max_node_count = var.batch_od_gke_node_count_max
  }

  node_config {
    machine_type    = var.batch_od_gke_machine_type
    disk_size_gb    = 100
    disk_type       = "pd-standard"
    service_account = google_service_account.gke_nodes.email

    taint {
      key    = "workload"
      value  = "batch-od"
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
