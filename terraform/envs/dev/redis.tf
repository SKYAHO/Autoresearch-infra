# #129 Feast Online Store Memorystore for Redis Cluster.
# Primary shard 2개와 replica 0개로 hash slot 분산을 학습하는 dev 구성이다.

resource "google_network_connectivity_service_connection_policy" "redis" {
  name          = local.redis_service_connection_policy_name
  location      = var.region
  service_class = "gcp-memorystore-redis"
  network       = google_compute_network.dev.id
  description   = "PSC automation policy for the Autoresearch dev Redis Cluster"

  psc_config {
    subnetworks = [google_compute_subnetwork.redis_psc.id]
    limit       = "2"
  }
}

resource "google_redis_cluster" "online_store" {
  name          = local.redis_cluster_name
  region        = var.region
  shard_count   = var.redis_shard_count
  replica_count = var.redis_replica_count
  node_type     = var.redis_node_type

  authorization_mode      = "AUTH_MODE_IAM_AUTH"
  transit_encryption_mode = "TRANSIT_ENCRYPTION_MODE_SERVER_AUTHENTICATION"
  server_ca_mode          = "SERVER_CA_MODE_GOOGLE_MANAGED_PER_INSTANCE_CA"

  deletion_protection_enabled = var.redis_cluster_deletion_protection

  psc_configs {
    network = google_compute_network.dev.id
  }

  zone_distribution_config {
    mode = "MULTI_ZONE"
  }

  persistence_config {
    mode = "DISABLED"
  }

  maintenance_policy {
    weekly_maintenance_window {
      day = "SUNDAY"

      start_time {
        hours   = 17
        minutes = 0
        seconds = 0
        nanos   = 0
      }
    }
  }

  depends_on = [google_network_connectivity_service_connection_policy.redis]
}

# IAM auth의 redis.clusters.connect 권한을 app GSA에만 부여하고 resource.name
# condition으로 이 cluster 하나에 제한한다. access token은 Workload Identity로
# 런타임 발급하며 Terraform/Secret Manager에 저장하지 않는다.
resource "google_project_iam_member" "gke_app_redis_connection" {
  project = var.project_id
  role    = "roles/redis.dbConnectionUser"
  member  = "serviceAccount:${google_service_account.gke_app.email}"

  condition {
    title       = "autoresearch-dev-redis-cluster-only"
    description = "Allow the app workload to authenticate only to the dev Online Store cluster."
    expression  = "resource.name == 'projects/${var.project_id}/locations/${var.region}/clusters/${local.redis_cluster_name}'"
  }
}
