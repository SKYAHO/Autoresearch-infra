locals {
  name_prefix       = "autoresearch"
  state_bucket_name = "${local.name_prefix}-dev-tfstate"
  wif_pool_id       = "${local.name_prefix}-github"
  wif_provider_id   = "github"
  ci_sa_id          = "terraform-ci"

  default_labels = {
    environment = "bootstrap"
    managed_by  = "terraform"
    project     = "autoresearch"
    repository  = "autoresearch-infra"
  }
}

# 원격 state 저장 버킷 (dev 루트가 backend 로 사용)
resource "google_storage_bucket" "tfstate" {
  name                        = local.state_bucket_name
  location                    = var.region
  project                     = var.project_id
  uniform_bucket_level_access = true
  force_destroy               = false
  public_access_prevention    = "enforced"

  versioning {
    enabled = true
  }

  labels = local.default_labels

  lifecycle {
    prevent_destroy = true
  }
}

# CI SA 가 state read/write 가능하도록(UBLA 이므로 버킷 IAM)
resource "google_storage_bucket_iam_member" "ci_state" {
  bucket = google_storage_bucket.tfstate.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.terraform_ci.email}"
}

# Workload Identity Federation 풀
resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = local.wif_pool_id
  project                   = var.project_id
  display_name              = "GitHub Actions"
  description               = "WIF pool for GitHub Actions OIDC (autoresearch-infra)."
}

# GitHub OIDC provider (attribute_condition 으로 repo 제한)
resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = local.wif_provider_id
  project                            = var.project_id

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.owner"      = "assertion.repository_owner"
    # #175 repo와 ref를 동시에 강제하는 조합 attribute. pusher SA
    # (쓰기 권한)의 principalSet을 repository만이 아니라 승인된 ref로
    # 제한하는 데 사용한다 — repository 단독 principalSet은 임의 브랜치의
    # workflow까지 SA 가장을 허용해 공급망 위험이 된다(Codex adversarial
    # review). 값 예: SKYAHO/Autoresearch-airflow@refs/heads/main
    "attribute.repository_ref" = "assertion.repository + '@' + assertion.ref"
  }

  attribute_condition = "attribute.repository in ${jsonencode(var.allowed_github_repositories)}"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# CI 용 service account (GitHub Actions 가 WIF 경유로 가장)
resource "google_service_account" "terraform_ci" {
  account_id   = local.ci_sa_id
  project      = var.project_id
  display_name = "Terraform CI (GitHub Actions)"
  description  = "Used by GitHub Actions for terraform plan (read-only)."
}

# plan 용 read 권한
resource "google_project_iam_member" "ci_viewer" {
  project = var.project_id
  role    = "roles/viewer"
  member  = "serviceAccount:${google_service_account.terraform_ci.email}"
}

# dev root plan은 bucket IAM member refresh 시 storage.buckets.getIamPolicy가 필요하다.
resource "google_project_iam_custom_role" "ci_storage_bucket_iam_viewer" {
  project     = var.project_id
  role_id     = "ci_storage_bucket_iam_viewer"
  title       = "Terraform CI Storage Bucket IAM Viewer"
  description = "Allows Terraform CI plan to read Cloud Storage bucket IAM policies."
  permissions = [
    "storage.buckets.getIamPolicy",
  ]
}

resource "google_project_iam_member" "ci_storage_bucket_iam_viewer" {
  project = var.project_id
  role    = google_project_iam_custom_role.ci_storage_bucket_iam_viewer.id
  member  = "serviceAccount:${google_service_account.terraform_ci.email}"
}

# GitHub repo -> CI SA 가장 허용 (repository 속성으로 제한)
resource "google_service_account_iam_member" "ci_wi" {
  service_account_id = google_service_account.terraform_ci.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repository}"
}
