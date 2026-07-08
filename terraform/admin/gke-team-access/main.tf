# Team member access is intentionally separated from terraform/envs/dev.
# This keeps personal email addresses and off-boarding churn out of PR plan comments.
#
# #45: role을 clusterViewer → container.viewer로 확대. DNS 기반 컨트롤 플레인
# 엔드포인트 접속에 필요한 container.clusters.connect가 clusterViewer에는 없고
# viewer(읽기 전용)에 포함되기 때문. GCP 리소스 변경 권한은 없다.
# 주의(의도된 결정): viewer는 IAM→k8s 매핑으로 클러스터 전역 k8s 오브젝트
# 읽기(secrets 제외)도 부여한다. 소규모 팀의 상호 가시성을 위해 전역 읽기를
# 허용하는 팀 방침이며, 쓰기/namespace 작업 권한은 여전히 RBAC(#32)로만 부여된다.
resource "google_project_iam_member" "gke_kubectl_users" {
  for_each = var.team_member_emails

  project = var.project_id
  role    = "roles/container.viewer"
  member  = "user:${each.value}"
}
