output "project_id" {
  description = "GCP project id used by the dev Terraform environment."
  value       = var.project_id
}

output "region" {
  description = "Default GCP region used by dev resources."
  value       = var.region
}

output "zone" {
  description = "Default GCP zone used by zonal dev resources."
  value       = var.zone
}

output "environment" {
  description = "Terraform environment name."
  value       = var.environment
}

output "resource_prefix" {
  description = "Common prefix for dev resource names."
  value       = local.resource_prefix
}

output "default_labels" {
  description = "Default labels applied to supported GCP resources."
  value       = local.default_labels
}

output "required_services" {
  description = "GCP APIs expected by the planned dev infrastructure work."
  value       = sort(tolist(local.required_services))
}

output "vpc_self_link" {
  description = "Self link of the dev VPC."
  value       = google_compute_network.dev.self_link
}

output "dev_subnet_self_link" {
  description = "Self link of the dev subnet. Cloud SQL / GKE 가 이 값을 참조한다."
  value       = google_compute_subnetwork.dev.self_link
}

