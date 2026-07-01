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

