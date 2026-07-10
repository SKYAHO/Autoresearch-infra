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

    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.13, < 3.0"
    }
  }

  backend "gcs" {
    bucket = "autoresearch-dev-tfstate"
    prefix = "admin/argocd-k8s/"
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
  host                   = "https://${data.google_container_cluster.dev.endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(data.google_container_cluster.dev.master_auth[0].cluster_ca_certificate)
}

provider "helm" {
  kubernetes {
    host                   = "https://${data.google_container_cluster.dev.endpoint}"
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = base64decode(data.google_container_cluster.dev.master_auth[0].cluster_ca_certificate)
  }
}
