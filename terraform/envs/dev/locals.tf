locals {
  resource_prefix = "${var.name_prefix}-${var.environment}"

  vpc_name        = "${local.resource_prefix}-vpc"
  dev_subnet_name = "${local.resource_prefix}-subnet"
  ssh_iap_tag     = "ssh-iap"

  default_labels = merge(
    {
      environment = var.environment
      managed_by  = "terraform"
      project     = "autoresearch"
      repository  = "autoresearch-infra"
    },
    var.labels
  )

  required_services = toset([
    "artifactregistry.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    "container.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "secretmanager.googleapis.com",
    "serviceusage.googleapis.com",
    "servicenetworking.googleapis.com",
    "sqladmin.googleapis.com",
    "sts.googleapis.com",
  ])

  ar_repo_id = "${local.resource_prefix}-docker"

  sql_instance_name = "${local.resource_prefix}-pg"
}

