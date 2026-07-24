# #316 CTR 재학습 전용 격리 노드풀. 라이브에는 #317 브랜치에서 이미 apply돼
# 있으므로, main 기준 첫 apply 전에 반드시 import 한다(리소스 재생성 방지):
#   terraform import google_container_node_pool.ctr_model_retrain \
#     projects/ar-infra-501607/locations/asia-northeast3-a/clusters/autoresearch-dev-gke/nodePools/ctr-model-retrain
# max는 #330에서 1→2로 상향(변수화): min 0 유지라 유휴 비용 불변, 병렬 재학습/HPO 대비.
resource "google_container_node_pool" "ctr_model_retrain" {
  name       = "ctr-model-retrain"
  cluster    = google_container_cluster.dev.name
  location   = var.zone
  node_count = 0

  autoscaling {
    min_node_count = 0 # 평시 0대 = 비용 0
    max_node_count = var.ctr_retrain_gke_node_count_max
  }

  node_config {
    # n2-highmem-4 = 4 vCPU / 32GB. e2-standard-8(8 vCPU/32GB)과 메모리는 같지만
    # E2_CPUS 리전 쿼터(한도 8, 기존 E2 노드가 이미 소진)에 막혀 scale-up이 실패해
    # N2 계열로 전환한다(N2_CPUS 쿼터 0/32로 여유). online_features 피크 헤드룸용 32GB.
    machine_type    = "n2-highmem-4"
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
