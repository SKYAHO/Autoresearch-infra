# #48 Airflow UI 내부 노출 — ILB 예약 내부 IP + Cloud DNS private zone
# Airflow webserver를 internal LoadBalancer로만 노출하고, VPC 내부 전용
# private DNS 이름(airflow.<domain>)을 부여한다. 인터넷 노출은 없다.
# 브라우저 접근은 Bastion(#47) 터널 경유. Helm Service 설정(어노테이션 +
# loadBalancerIP)은 앱 저장소가 관리하며, 가이드는 docs/TERRAFORM_DEV.md
# "#48" 섹션 참조.

# ILB VIP로 쓸 예약 내부 IP. Helm values의 loadBalancerIP가 이 output 값을 참조한다.
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

# #244 MLflow UI 내부 노출 — Airflow(#48)와 동일 패턴. 내부 LoadBalancer는
# oauth2-proxy(4180) 앞단에만 붙이고(인증 유지), mlflow:5000은 ClusterIP 내부
# 전용을 유지한다. 이 VIP는 deploy/mlflow oauth2-proxy Service의 loadBalancerIP가
# 참조한다. 인터넷 노출 없음, 접근은 Bastion(#47) 터널 경유.
resource "google_compute_address" "mlflow_ilb" {
  name         = "${local.resource_prefix}-mlflow-ilb"
  region       = var.region
  address_type = "INTERNAL"
  subnetwork   = google_compute_subnetwork.dev.self_link
  purpose      = "SHARED_LOADBALANCER_VIP"
}

resource "google_dns_record_set" "mlflow" {
  managed_zone = google_dns_managed_zone.internal.name
  name         = "mlflow.${var.internal_dns_domain}."
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_address.mlflow_ilb.address]
}

# #138 Google API 트래픽을 private.googleapis.com 고정 VIP(199.36.153.8/30)로
# 유도하는 VPC 전용 zone. googleapis.com만 override하므로 pkg.dev(이미지 pull),
# run.app(Cloud Run), metadata 경로는 영향이 없다. 이 zone 덕분에 Google API만
# 필요한 namespace(vault 등)는 egress 443을 고정 CIDR로 좁힐 수 있다.
# 제거 시 TTL(300s) 이내에 공개 IP 해석으로 복귀한다.
resource "google_dns_managed_zone" "private_googleapis" {
  name        = "${local.resource_prefix}-private-googleapis"
  dns_name    = "googleapis.com."
  description = "Route Google APIs via private.googleapis.com VIPs (#138)"
  visibility  = "private"

  private_visibility_config {
    networks {
      network_url = google_compute_network.dev.id
    }
  }
}

resource "google_dns_record_set" "private_googleapis_a" {
  managed_zone = google_dns_managed_zone.private_googleapis.name
  name         = "private.googleapis.com."
  type         = "A"
  ttl          = 300
  rrdatas      = ["199.36.153.8", "199.36.153.9", "199.36.153.10", "199.36.153.11"]
}

resource "google_dns_record_set" "private_googleapis_cname" {
  managed_zone = google_dns_managed_zone.private_googleapis.name
  name         = "*.googleapis.com."
  type         = "CNAME"
  ttl          = 300
  rrdatas      = ["private.googleapis.com."]
}
