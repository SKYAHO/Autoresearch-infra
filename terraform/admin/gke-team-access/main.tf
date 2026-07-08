# Team member access is intentionally separated from terraform/envs/dev.
# This keeps personal email addresses and off-boarding churn out of PR plan comments.
#
# #45: role을 clusterViewer → container.viewer로 확대. DNS 기반 컨트롤 플레인
# 엔드포인트 접속에 필요한 container.clusters.connect가 clusterViewer에는 없고
# viewer(읽기 전용)에 포함되기 때문. GCP 리소스 변경 권한은 여전히 없다.
resource "google_project_iam_member" "gke_kubectl_users" {
  for_each = var.team_member_emails

  project = var.project_id
  role    = "roles/container.viewer"
  member  = "user:${each.value}"
}
