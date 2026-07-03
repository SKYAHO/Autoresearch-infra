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

output "artifact_registry_repo_id" {
  description = "Artifact Registry Docker repository id (배포 workflow 참조)."
  value       = google_artifact_registry_repository.dev.repository_id
}

output "artifact_registry_image_url" {
  description = "Base image URL for pushing/pulling dev Docker images: <location>-docker.pkg.dev/<project>/<repo>."
  value       = "${google_artifact_registry_repository.dev.location}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.dev.repository_id}"
}

output "cloud_sql_instance_connection_name" {
  description = "Cloud SQL instance connection name (Cloud SQL Auth Proxy / Connector 용)."
  value       = google_sql_database_instance.dev.connection_name
}

output "cloud_sql_private_ip_address" {
  description = "Private IP address of the dev Cloud SQL instance (VPC 내부 접근)."
  value       = google_sql_database_instance.dev.private_ip_address
}

output "cloud_sql_database_name" {
  description = "dev application database name."
  value       = google_sql_database.dev.name
}

output "gke_cluster_name" {
  description = "dev GKE 클러스터 이름."
  value       = google_container_cluster.dev.name
}

output "gke_cluster_endpoint" {
  description = "dev GKE API endpoint."
  value       = google_container_cluster.dev.endpoint
}

output "gke_cluster_ca_certificate" {
  description = "dev GKE 클러스터 CA 인증서(base64)."
  value       = google_container_cluster.dev.master_auth[0].cluster_ca_certificate
  sensitive   = true
}

output "gke_node_service_account_email" {
  description = "노드 풀에 연결된 GCP 서비스 계정(AR pull/로깅/모니터링)."
  value       = google_service_account.gke_nodes.email
}

output "gke_app_service_account_email" {
  description = "app Workload Identity용 GCP 서비스 계정(Cloud SQL/Secret)."
  value       = google_service_account.gke_app.email
}

output "gke_workload_identity_principal" {
  description = "KSA가 가장할 principal 식별자. app KSA annotation에 사용."
  value       = local.gke_workload_identity_principal
}

output "db_app_password_secret_id" {
  description = "DB app 비밀번호 Secret Manager secret id."
  value       = google_secret_manager_secret.db_app_password.id
}

