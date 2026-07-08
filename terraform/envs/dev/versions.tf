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
