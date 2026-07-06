output "tf_state_bucket_name" {
  description = "GCS bucket name for Terraform remote state (dev)."
  value       = google_storage_bucket.tfstate.name
}

output "tf_state_bucket_self_link" {
  description = "Self link of the Terraform state GCS bucket."
  value       = google_storage_bucket.tfstate.self_link
}

output "wif_pool_name" {
  description = "Full WIF pool name: projects/<N>/locations/global/workloadIdentityPools/autoresearch-github"
  value       = google_iam_workload_identity_pool.github.name
}

output "wif_provider_name" {
  description = "Full WIF provider name: projects/<N>/.../providers/github"
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "ci_service_account_email" {
  description = "CI service account email (GitHub Actions impersonates via WIF)."
  value       = google_service_account.terraform_ci.email
}
