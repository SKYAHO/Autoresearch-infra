# Team member access is intentionally separated from terraform/envs/dev.
# This keeps personal email addresses and off-boarding churn out of PR plan comments.
#
# #45(리뷰 반영): DNS 엔드포인트 접속에 필요한 최소 권한만 담은 커스텀 role을
# 사용한다. roles/container.viewer는 connect 외에 클러스터 전역 k8s 오브젝트
# 읽기(pods/deployments 등)까지 부여해 namespace 격리(RBAC)를 읽기에 한해
# 무력화하므로 채택하지 않는다. k8s 내부 권한은 기존 RBAC(#32)로만 부여된다.
resource "google_project_iam_custom_role" "gke_dns_connect" {
  role_id     = "gkeDnsEndpointConnect"
  title       = "GKE DNS endpoint connect"
  description = "container.clusters.get/connect only - kubeconfig 발급과 DNS 엔드포인트 접속(#45)"
  permissions = [
    "container.clusters.get",
    "container.clusters.connect",
  ]
}

resource "google_project_iam_member" "gke_kubectl_users" {
  for_each = var.team_member_emails

  project = var.project_id
  role    = google_project_iam_custom_role.gke_dns_connect.id
  member  = "user:${each.value}"
}
