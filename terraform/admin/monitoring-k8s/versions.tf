terraform {
  # #183 removed 블록(안전 state 제거) 사용 — Terraform 1.7+ 필요.
  required_version = ">= 1.7.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0, < 8.0"
    }

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.20"
    }

    # #183 removed 블록이 helm_release 타입을 참조하므로 provider 유지.
    # 이관 완료(state에서 제거)된 뒤 별도 정리 PR에서 removed 블록과 함께 제거.
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.13, < 3.0"
    }
  }

  backend "gcs" {
    bucket = "autoresearch-dev-tfstate"
    prefix = "admin/monitoring-k8s/"
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
  host  = "https://${data.google_container_cluster.dev.control_plane_endpoints_config[0].dns_endpoint_config[0].endpoint}"
  token = data.google_client_config.default.access_token
}
