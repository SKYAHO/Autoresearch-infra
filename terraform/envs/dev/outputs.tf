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

output "gke_dns_endpoint" {
  description = "GKE 컨트롤 플레인 DNS 엔드포인트. IP 등록 없이 IAM으로 kubectl 접속하는 주소(#45)."
  value       = google_container_cluster.dev.control_plane_endpoints_config[0].dns_endpoint_config[0].endpoint
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

output "airflow_gke_node_pool_name" {
  description = "Airflow Helm component 전용 dev GKE node pool 이름."
  value       = google_container_node_pool.airflow.name
}

output "airflow_batch_workload_identity_principal" {
  description = "Airflow batch KSA가 app GSA를 가장할 Workload Identity principal."
  value       = local.airflow_batch_workload_identity_principal
}

output "cloud_build_compute_service_account_email" {
  description = "Autoresearch-airflow Cloud Build가 image build/push에 사용하는 Compute default service account."
  value       = local.cloud_build_compute_service_account_email
}

output "cloud_build_bucket_name" {
  description = "Cloud Build default staging bucket name used by Autoresearch-airflow builds."
  value       = local.cloud_build_bucket_name
}

output "airflow_api_k8s_secret_name" {
  description = "Airflow KPO pods에 YouTube/OpenRouter API key를 주입하는 Kubernetes Secret 이름."
  value       = var.airflow_api_k8s_secret_name
}

output "db_app_password_secret_id" {
  description = "DB app 비밀번호 Secret Manager secret id."
  value       = google_secret_manager_secret.db_app_password.id
}

output "raw_data_bucket_name" {
  description = "YouTube/user/action-log/persona 원본 전체를 저장하는 dev GCS bucket 이름."
  value       = google_storage_bucket.raw_data.name
}

output "raw_data_bucket_url" {
  description = "dev 원본 데이터 GCS bucket URL."
  value       = google_storage_bucket.raw_data.url
}

output "raw_data_prefixes" {
  description = "원본 데이터 유형별 GCS object prefix 규칙."
  value       = local.raw_data_prefixes
}

output "bigquery_dataset_id" {
  description = "dev 분석용 BigQuery dataset id."
  value       = google_bigquery_dataset.analytics.dataset_id
}

output "bigquery_dataset_self_link" {
  description = "dev 분석용 BigQuery dataset self link."
  value       = google_bigquery_dataset.analytics.self_link
}

output "feast_offline_store_dataset_id" {
  description = "Feast offline store BigQuery dataset id."
  value       = google_bigquery_dataset.feast_offline_store.dataset_id
}

output "feast_registry_bucket_name" {
  description = "Feast registry GCS bucket 이름."
  value       = google_storage_bucket.feast_registry.name
}

output "feast_registry_bucket_url" {
  description = "Feast registry GCS bucket URL."
  value       = google_storage_bucket.feast_registry.url
}

output "feast_staging_bucket_name" {
  description = "Feast staging GCS bucket 이름."
  value       = google_storage_bucket.feast_staging.name
}

output "feast_staging_bucket_url" {
  description = "Feast staging GCS bucket URL."
  value       = google_storage_bucket.feast_staging.url
}

output "proxy_service_name" {
  description = "dev proxy Cloud Run 서비스 이름."
  value       = google_cloud_run_v2_service.proxy.name
}

output "proxy_service_uri" {
  description = "dev proxy Cloud Run 서비스 URI. collector가 호출할 엔드포인트."
  value       = google_cloud_run_v2_service.proxy.uri
}

output "proxy_sa_email" {
  description = "proxy Cloud Run 런타임 service account email."
  value       = google_service_account.proxy.email
}

output "airflow_k8s_namespace" {
  description = "Airflow가 배포되는 Kubernetes namespace."
  value       = var.airflow_k8s_namespace
}

output "airflow_k8s_service_account" {
  description = "Airflow Workload Identity 매핑용 KSA 이름."
  value       = var.airflow_k8s_service_account
}

output "airflow_gcp_service_account_email" {
  description = "Airflow Workload Identity용 GCP 서비스 계정(Cloud SQL, BigQuery, GCS 최소 권한)."
  value       = google_service_account.airflow.email
}

output "airflow_workload_identity_principal" {
  description = "Airflow KSA가 가장할 principal 식별자."
  value       = local.airflow_workload_identity_principal
}

output "airflow_metadata_database_name" {
  description = "Airflow metadata DB(Cloud SQL 내 database 이름)."
  value       = google_sql_database.airflow.name
}

output "airflow_youtube_api_key_secret_id" {
  description = "Airflow YouTube API key Secret Manager secret id. Payload is managed outside Terraform."
  value       = google_secret_manager_secret.airflow_youtube_api_key.secret_id
}

output "airflow_openrouter_api_key_secret_id" {
  description = "Airflow OpenRouter API key Secret Manager secret id. Payload is managed outside Terraform."
  value       = google_secret_manager_secret.airflow_openrouter_api_key.secret_id
}

output "airflow_dags_bucket_name" {
  description = "Airflow DAG 저장 GCS bucket 이름."
  value       = google_storage_bucket.airflow_dags.name
}

output "airflow_logs_bucket_name" {
  description = "Airflow task log 저장 GCS bucket 이름."
  value       = google_storage_bucket.airflow_logs.name
}

output "bastion_instance_name" {
  description = "IAP 터널 전용 bastion VM 이름(#47). 비활성화 시 null."
  value       = var.bastion_enabled ? google_compute_instance.bastion[0].name : null
}

output "bastion_internal_ip" {
  description = "bastion 내부 IP. VPC 내부 서비스 접근 터널 종단."
  value       = var.bastion_enabled ? google_compute_instance.bastion[0].network_interface[0].network_ip : null
}

output "airflow_ilb_ip" {
  description = "Airflow webserver internal LB 예약 내부 IP(#48). Helm values loadBalancerIP로 사용."
  value       = google_compute_address.airflow_ilb.address
}

output "airflow_internal_fqdn" {
  description = "Airflow UI 내부 도메인(#48). Bastion 터널 상태에서 브라우저 접속 주소."
  value       = trimsuffix(google_dns_record_set.airflow.name, ".")
}

output "airflow_oauth_client_id_secret_id" {
  description = "Airflow Google OAuth client ID Secret Manager secret id(#54). Payload is managed outside Terraform."
  value       = google_secret_manager_secret.airflow_oauth_client_id.secret_id
}

output "airflow_oauth_client_secret_secret_id" {
  description = "Airflow Google OAuth client secret Secret Manager secret id(#54). Payload is managed outside Terraform."
  value       = google_secret_manager_secret.airflow_oauth_client_secret.secret_id
}
