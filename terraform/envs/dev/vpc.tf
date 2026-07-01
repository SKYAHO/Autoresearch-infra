# #2 dev VPC 및 subnet (custom mode)
# 이후 Cloud SQL / GKE는 google_compute_subnetwork.dev.self_link 를 참조한다.

resource "google_compute_network" "dev" {
  name                    = local.vpc_name
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

resource "google_compute_subnetwork" "dev" {
  name                     = local.dev_subnet_name
  ip_cidr_range            = var.dev_subnet_cidr
  region                   = var.region
  network                  = google_compute_network.dev.id
  private_ip_google_access = var.enable_private_google_access
}

# ponytail: 최소 ingress — IAP 경유 SSH만 허용. 추가 포트는 필요 시 별도 규칙으로.
resource "google_compute_firewall" "allow_ssh_iap" {
  name          = "${local.resource_prefix}-allow-ssh-iap"
  network       = google_compute_network.dev.id
  direction     = "INGRESS"
  source_ranges = ["35.235.240.0/20"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}
