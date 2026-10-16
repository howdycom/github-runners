# A minimal root that deploys the runners module from this checkout.
#
# To deploy from another repository, copy this directory and set source to a
# pinned version of this repo:
#   source = "git::https://github.com/<org>/github-runners.git//gcp?ref=<commit or tag>"
terraform {
  required_version = ">= 1.5"

  # The bucket and prefix are passed at init time, so no real names are
  # committed to this public repo: terraform init -backend-config=backend.hcl
  backend "gcs" {}

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

module "runners" {
  source = "../"

  project_id                    = var.project_id
  region                        = var.region
  github_org                    = var.github_org
  github_app_id                 = var.github_app_id
  github_app_installation_id    = var.github_app_installation_id
  github_app_private_key_secret = var.github_app_private_key_secret
  github_webhook_secret_id      = var.github_webhook_secret_id
  runner_group                  = var.runner_group
  repositories                  = var.repositories

  # Optional settings are module inputs with defaults; see ../variables.tf.
  # For example: machine_type = "n2d-standard-2", max_vms = 20.
  # Heavy pool, after baking the github-runner-heavy family:
  #   heavy_machine_type           = "e2-standard-8"
  #   heavy_fallback_machine_types = ["n2-standard-8"]
}
