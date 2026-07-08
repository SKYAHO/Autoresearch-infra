# #47 dev Bastion Host — IAP 터널 전용 내부 접근 경로
# 외부 IP 없음. SSH 진입은 IAP TCP forwarding(기존 ssh-iap firewall)으로만 가능.
# 용도: Airflow UI(#48 ILB) 등 VPC 내부 서비스로의 포트 포워딩/SOCKS 프록시 종단.
# kubectl 접근은 #45 DNS 엔드포인트로 해결되므로 이 VM을 경유하지 않는다.
#
# 접속 권한(팀원): terraform/admin/gke-team-access에서 IAM으로 관리
# (roles/iap.tunnelResourceAccessor + roles/compute.osLogin + roles/compute.viewer).

resource "google_service_account" "bastion" {
  account_id   = local.bastion_name
  display_name = "Autoresearch dev bastion SA (role 없음)"
}

resource "google_compute_instance" "bastion" {
  count = var.bastion_enabled ? 1 : 0

  name         = local.bastion_name
  machine_type = var.bastion_machine_type
  zone         = var.zone

  tags = [local.ssh_iap_tag]

  boot_disk {
    initialize_params {
      image = var.bastion_image
      size  = var.bastion_disk_size_gb
      type  = "pd-standard"
    }
  }

  # 외부 IP 없음(access_config 미설정). OS 패키지 업데이트 등 egress는 Cloud NAT 경유.
  network_interface {
    subnetwork = google_compute_subnetwork.dev.self_link
  }

  # SSH 키 배포 대신 OS Login: 접속 가능 계정을 IAM으로 통제.
  metadata = {
    enable-oslogin = "TRUE"
  }

  service_account {
    email  = google_service_account.bastion.email
    scopes = ["cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  # 미사용 기간에는 수동 정지로 비용 절감 가능(gcloud compute instances stop).
  allow_stopping_for_update = true
}
