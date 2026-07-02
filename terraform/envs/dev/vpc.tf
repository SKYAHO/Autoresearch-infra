# #2 dev VPC 및 subnet (custom mode)
# 이후 Cloud SQL / GKE는 google_compute_subnetwork.dev.self_link 를 참조한다.

resource "google_compute_network" "dev" {
  name                    = local.vpc_name
  auto_create_subnetworks = false
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
  source_ranges = ["35.235.240.0/20"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

# PGA: 외부 IP 없는 VM이 Google API 에 도달하려면 default-internet-gateway 라우트가 필요.
# custom mode VPC 는 자동 기본 라우트를 만들지 않으므로 명시적으로 생성한다.
# ponytail: restricted.googleapis.com(199.36.153.8/30)만. private.googleapis.com(199.36.135.0/25)
# 범위가 필요한 서비스가 생기면 동일한 next_hop 으로 라우트 한 줄 더 추가.
resource "google_compute_route" "pga_restricted" {
  count            = var.enable_private_google_access ? 1 : 0
  name             = "${local.resource_prefix}-pga-restricted"
  network          = google_compute_network.dev.id
  dest_range       = "199.36.153.8/30"
  next_hop_gateway = "default-internet-gateway"
}
