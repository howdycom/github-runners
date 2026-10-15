terraform {
  required_version = ">= 1.5"

  # The bucket and prefix are passed at init time, so no real names are
  # committed to this public repo: terraform init -backend-config=backend.hcl
  backend "gcs" {}

  required_providers {
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
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
