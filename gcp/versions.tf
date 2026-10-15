terraform {
  required_version = ">= 1.5"

  # The bucket and prefix are passed at init time, so no real names are
  # committed to this public repo: terraform init -backend-config=backend.hcl
  backend "gcs" {}

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0, < 8"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 6.0, < 8"
    }
    # gh-runner-gke 5.1.0 uses the helm 2.x `set {}` block syntax.
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }
}
