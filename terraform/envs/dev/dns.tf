# #48 Airflow UI 내부 노출 — ILB 고정 IP + Cloud DNS private zone
# Airflow webserver를 internal LoadBalancer로만 노출하고, VPC 내부 전용
# private DNS 이름(airflow.<domain>)을 부여한다. 인터넷 노출은 없다.
# 브라우저 접근은 Bastion(#47) 터널 경유. Helm Service 설정(어노테이션 +
# loadBalancerIP)은 앱 저장소가 관리하며, 가이드는 docs/TERRAFORM_DEV.md
# "#48" 섹션 참조.

# ILB VIP로 쓸 내부 고정 IP. Helm values의 loadBalancerIP가 이 값을 참조한다.
resource "google_compute_address" "airflow_ilb" {
  name         = "${local.resource_prefix}-airflow-ilb"
  region       = var.region
  address_type = "INTERNAL"
  subnetwork   = google_compute_subnetwork.dev.self_link
  purpose      = "SHARED_LOADBALANCER_VIP"
}

# VPC 내부 전용 private zone. 외부에서는 조회 불가.
resource "google_dns_managed_zone" "internal" {
  name        = "${local.resource_prefix}-internal"
  dns_name    = "${var.internal_dns_domain}."
  description = "Dev VPC private DNS zone for internal services (#48)"
  visibility  = "private"

  private_visibility_config {
    networks {
      network_url = google_compute_network.dev.id
    }
  }
}

resource "google_dns_record_set" "airflow" {
  managed_zone = google_dns_managed_zone.internal.name
  name         = "airflow.${var.internal_dns_domain}."
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_address.airflow_ilb.address]
}
