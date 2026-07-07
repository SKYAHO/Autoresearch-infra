# #31 팀원 GKE kubectl 접근 경로
# roles/container.clusterViewer는 container.clusters.get/list 권한을 부여한다.
# 본 클러스터는 public endpoint + master_authorized_networks라 get만 필요(connect는 private endpoint용).
# ponytail: project-level이라 클러스터 추가 시 자동 확대. dev 단일 클러스터 전제. 팀원 이메일은 var(tfvars 로컬)에서 관리.
resource "google_project_iam_member" "gke_kubectl_users" {
  for_each = var.gke_kubectl_user_emails

  project = var.project_id
  role    = "roles/container.clusterViewer"
  member  = "user:${each.value}"
}
