terraform {
  # >= 1.7.0: removed 블록(state에서만 분리, destroy 없이 forget) 사용 —
  # #478 Vault 리소스 제거가 첫 사용처.
  required_version = ">= 1.7.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 7.39.0, < 8.0"
    }

    random = {
      source  = "hashicorp/random"
      version = ">= 3.0"
    }

  }

  backend "gcs" {
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone

  default_labels = local.default_labels
}
