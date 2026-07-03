# private GKE 노드의 아웃바운드(AR pull 등)용 Cloud NAT.
# ponytail: AR(*.pkg.dev)은 PGA(restricted.googleapis.com) 범위 밖이라 NAT 필요.
resource "google_compute_router" "dev" {
  name    = "${local.resource_prefix}-router"
  region  = var.region
  network = google_compute_network.dev.id
}

resource "google_compute_router_nat" "dev" {
  name                               = "${local.resource_prefix}-nat"
  router                             = google_compute_router.dev.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_PRIMARY_IP_RANGES"

  depends_on = [google_compute_subnetwork.dev]
}
