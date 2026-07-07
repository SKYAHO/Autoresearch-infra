terraform {
  required_version = ">= 1.6.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0, < 8.0"
    }

    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 5.0, < 8.0"
    }

    random = {
      source  = "hashicorp/random"
      version = ">= 3.0"
    }

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.20"
    }
  }

  backend "gcs" {
    bucket = "autoresearch-dev-tfstate"
    prefix = "dev/"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone

  default_labels = local.default_labels
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
  zone    = var.zone

  default_labels = local.default_labels
}

data "google_client_config" "default" {}

# ponytail: apply 시점 ADC/WIF로 cluster 접근. 별도 kubeconfig 불필요.
provider "kubernetes" {
  host                   = "https://${google_container_cluster.dev.endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(google_container_cluster.dev.master_auth.0.cluster_ca_certificate)
}
