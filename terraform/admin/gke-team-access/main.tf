# Team member access is intentionally separated from terraform/envs/dev.
# This keeps personal email addresses and off-boarding churn out of PR plan comments.
resource "google_project_iam_member" "gke_kubectl_users" {
  for_each = var.team_member_emails

  project = var.project_id
  role    = "roles/container.clusterViewer"
  member  = "user:${each.value}"
}

# #47 Bastion IAP 터널 접속 3종. 모두 읽기/접속용이며 리소스 변경 권한 없음.
# - iap.tunnelResourceAccessor: IAP TCP forwarding 통과
# - compute.osLogin: SSH 키 배포 없이 IAM 기반 SSH 로그인
# - compute.viewer: gcloud compute ssh가 요구하는 instance 조회
resource "google_project_iam_member" "bastion_iap_tunnel_users" {
  for_each = var.team_member_emails

  project = var.project_id
  role    = "roles/iap.tunnelResourceAccessor"
  member  = "user:${each.value}"
}

resource "google_project_iam_member" "bastion_oslogin_users" {
  for_each = var.team_member_emails

  project = var.project_id
  role    = "roles/compute.osLogin"
  member  = "user:${each.value}"
}

resource "google_project_iam_member" "bastion_compute_viewer_users" {
  for_each = var.team_member_emails

  project = var.project_id
  role    = "roles/compute.viewer"
  member  = "user:${each.value}"
}
