# This directory is a module: the caller configures the backend and the google
# provider (project and region). example/ is a minimal root that does both.
terraform {
  required_version = ">= 1.5"

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
