terraform {
  required_version = ">= 1.6.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0, < 8.0"
    }

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.20"
    }
  }

  backend "gcs" {
    bucket = "autoresearch-dev-tfstate"
    prefix = "admin/airflow-k8s/"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

data "google_client_config" "default" {}

data "google_container_cluster" "dev" {
  name     = var.gke_cluster_name
  location = var.zone
  project  = var.project_id
}

provider "kubernetes" {
  # GitHub-hosted and operator networks may not reach the legacy IP endpoint.
  # GKE DNS endpoint access is IAM-authenticated and is the supported path for
  # this cluster; the deployer GSA has container.clusterViewer for connect.
  host  = "https://${data.google_container_cluster.dev.control_plane_endpoints_config[0].dns_endpoint_config[0].endpoint}"
  token = data.google_client_config.default.access_token
}
