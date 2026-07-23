resource "google_container_node_pool" "ctr_model_retrain" {
  name       = "ctr-model-retrain"
  cluster    = google_container_cluster.dev.name
  location   = var.zone
  node_count = 0

  autoscaling {
    min_node_count = 0 # 평시 0대 = 비용 0
    max_node_count = 1 # 재학습은 단일 Pod
  }

  node_config {
    machine_type    = "e2-standard-8" # 32GB. online_features 피크(6Gi+ 초과, 미상) 넉넉히 덮음
    disk_size_gb    = 30
    disk_type       = "pd-standard" # SSD_TOTAL_GB quota 여유 없음(#98 교훈)
    spot            = false         # 1회성 재학습이라 중간 evict 방지(batch_spot과 다른 점)
    service_account = google_service_account.gke_nodes.email

    taint {
      key    = "dedicated"
      value  = "ctr-model-retrain"
      effect = "NO_SCHEDULE" # ← Terraform은 NO_SCHEDULE (k8s toleration은 NoSchedule)
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }

  lifecycle {
    ignore_changes = [node_count]
  }
}