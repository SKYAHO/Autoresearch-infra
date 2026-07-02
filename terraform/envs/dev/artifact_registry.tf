# #3 Artifact Registry Docker repository
# 컨테이너 이미지 저장소. push/pull IAM 은 컨슈머(GitHub OIDC SA / GKE 노드 SA) 이슈에서 바인딩한다.
# ponytail: 리포만 생성. IAM 바인딩은 대상 SA 가 생기는 각 이슈에서 추가.

resource "google_artifact_registry_repository" "dev" {
  location      = var.region
  repository_id = local.ar_repo_id
  format        = "DOCKER"
  description   = "Docker images for the autoresearch dev environment."
}
