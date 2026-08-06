variable "project_id" {
  description = "GCP project id for bootstrap infrastructure (state bucket, WIF, CI SA)."
  type        = string
}

variable "github_repository" {
  description = "GitHub repository allowed to impersonate the CI SA via WIF (owner/name)."
  type        = string
  default     = "SKYAHO/Autoresearch-infra"
}

variable "allowed_github_repositories" {
  description = "GitHub repositories allowed to obtain an OIDC token from this WIF provider (owner/name list). The CI SA impersonation is still restricted to var.github_repository by a separate IAM binding."
  type        = list(string)
  default = [
    "SKYAHO/Autoresearch-infra",
    "SKYAHO/Autoresearch-airflow",
    "SKYAHO/Autoresearch",
  ]
}

variable "feast_apply_github_repository" {
  description = "GitHub repository allowed to obtain Feast apply WIF tokens (owner/name). Each provider also requires its matching GitHub Environment."
  type        = string
  default     = "SKYAHO/Autoresearch"
}

# workflow_ref 는 워크플로우가 **실행된 ref** 를 담으므로 환경마다 다르다. 두
# provider 가 같은 값을 쓰면 한쪽은 반드시 어긋난다(#548) — feast-apply 는
# `on.push.branches: [main, dev]` 라서 dev push 의 workflow_ref 가
# `@refs/heads/dev` 로 온다. 그래서 환경별 목록으로 분리한다.
variable "feast_apply_prod_workflow_refs" {
  description = "GitHub Actions workflow_refs allowed to obtain prod Feast apply WIF tokens. prod는 main push와 main에서의 workflow_dispatch뿐이라 ref가 하나다."
  type        = list(string)
  default = [
    "SKYAHO/Autoresearch/.github/workflows/feast-apply.yml@refs/heads/main",
  ]
}

variable "feast_apply_dev_workflow_refs" {
  description = "GitHub Actions workflow_refs allowed to obtain dev Feast apply WIF tokens. dev push(@refs/heads/dev)와 main에서 environment=dev로 실행하는 workflow_dispatch(@refs/heads/main)를 모두 받는다."
  type        = list(string)
  default = [
    "SKYAHO/Autoresearch/.github/workflows/feast-apply.yml@refs/heads/dev",
    "SKYAHO/Autoresearch/.github/workflows/feast-apply.yml@refs/heads/main",
  ]
}

variable "region" {
  # bootstrap은 카탈로그 공급 대상이 아니므로(#413 보호 유지) 여기서 default를
  # 없애면 공급원이 사라진다. region은 state 버킷 이름과 달리 전역 유니크가
  # 아니어서 기본값이 안전하며, 다른 리전에 부트스트랩하려면 -var로 덮는다.
  description = "Location for the Terraform state GCS bucket."
  type        = string
  default     = "asia-northeast3"
}

variable "state_bucket_name" {
  description = "Terraform state GCS bucket name. Bucket names are globally unique, so no default can be safe across projects — always pass the value for the project being bootstrapped (#413). Must match the backend bucket in every root's versions.tf."
  type        = string
}
