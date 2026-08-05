# #533 GitHub Actions 셀프 호스티드 러너(ARC) PoC. K8s 설치(namespace/KSA/
# NetworkPolicy)는 terraform/admin/actions-runner-k8s가 담당하고, dev root는
# GCP 측(GSA, WI, Secret Manager 컨테이너)만 관리한다 — elastic.tf와 동일한
# GCP/K8s root 분리 관례를 따른다.

# ARC 컨트롤러 매니저 Pod 전용 GSA. 러너(listener/ephemeral runner) Pod는 GCP
# API를 직접 호출하지 않으므로 이 GSA를 공유하지 않는다.
resource "google_service_account" "actions_runner_controller" {
  account_id   = local.actions_runner_controller_sa_name
  display_name = "Autoresearch dev ARC controller SA"
  description  = "ARC 컨트롤러 매니저 Pod 전용. Kubernetes API 관리 목적, GCP 리소스 권한 없음."
}

resource "google_service_account_iam_member" "actions_runner_controller_wi" {
  service_account_id = google_service_account.actions_runner_controller.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.actions_runner_controller_workload_identity_principal}"

  depends_on = [google_container_cluster.dev]
}

# GitHub App 자격 증명 컨테이너. 값은 Terraform이 관리하지 않는다 — GitHub App은
# 조직 GitHub UI에서 수동 생성하고, 값은 운영자가 gcloud로 직접 채운다
# (argocd_google_oidc_client와 동일 패턴). ARC 러너 Pod는 이 값을 Secret
# Manager API가 아니라 운영자가 만드는 네이티브 K8s Secret으로 소비하므로
# 컨트롤러 GSA에 secretmanager accessor를 부여하지 않는다.
resource "google_secret_manager_secret" "actions_runner_github_app" {
  for_each = toset([
    "actions-runner-github-app-id",
    "actions-runner-github-app-installation-id",
    "actions-runner-github-app-private-key",
  ])
  secret_id = each.key

  replication {
    auto {}
  }

  lifecycle {
    prevent_destroy = true
  }
}
