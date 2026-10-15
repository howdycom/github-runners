variable "project_id" {
  type        = string
  description = "GCP project that holds the runner cluster. Use a project dedicated to CI."
}

variable "region" {
  type        = string
  description = "GCP region for the network and the cluster."
  default     = "us-central1"
}

variable "zone" {
  type        = string
  description = "GCP zone for the zonal cluster. It must be in var.region."
  default     = "us-central1-a"
}

variable "cluster_suffix" {
  type        = string
  description = "Suffix of the cluster name. The cluster is named gh-runner-<suffix>."
  default     = "arc"
}

variable "network_name" {
  type        = string
  description = "Name of the VPC network created for the runners."
  default     = "gh-runners"
}

variable "subnet_name" {
  type        = string
  description = "Name of the subnet created for the runners."
  default     = "gh-runners"
}

variable "subnet_cidr" {
  type        = string
  description = "Primary range of the runner subnet (nodes)."
  default     = "10.10.0.0/20"
}

variable "pods_cidr" {
  type        = string
  description = "Secondary range for pods."
  default     = "10.20.0.0/16"
}

variable "services_cidr" {
  type        = string
  description = "Secondary range for services."
  default     = "10.30.0.0/20"
}

variable "github_config_url" {
  type        = string
  description = "GitHub organization the runners register to, for example https://github.com/your-org."

  validation {
    condition     = can(regex("^https://github\\.com/[^/]+/?$", var.github_config_url))
    error_message = "Use an organization URL such as https://github.com/your-org."
  }
}

variable "github_app_id" {
  type        = string
  description = "App ID of the GitHub App that ARC uses to register runners."
}

variable "github_app_installation_id" {
  type        = string
  description = "Installation ID of that GitHub App in the organization."
}

variable "github_app_private_key_secret" {
  type        = string
  description = "Secret Manager secret ID (in var.project_id) that holds the GitHub App private key in PEM format."
}

variable "github_app_private_key_secret_version" {
  type        = string
  description = "Version of the private key secret to read."
  default     = "latest"
}

variable "runner_group" {
  type        = string
  description = "GitHub runner group for the scale set. Use a group that public repositories cannot use, limited to the repositories that need these runners."

  validation {
    condition     = length(trimspace(var.runner_group)) > 0 && lower(var.runner_group) != "default"
    error_message = "Set a dedicated runner group. The Default group can be shared with every repository in the organization."
  }
}

variable "runner_scale_set_name" {
  type        = string
  description = "Name of the runner scale set. Workflows select these runners with runs-on: <this name>."
  default     = "gcp-heavy"
}

variable "max_runners" {
  type        = number
  description = "Maximum number of concurrent runners. Each runner gets its own node."
  default     = 8

  validation {
    condition     = var.max_runners >= 1
    error_message = "max_runners must be at least 1."
  }
}

variable "min_nodes" {
  type        = number
  description = "Nodes kept running when no job is queued. ARC's controller and listener run there. Must be at least 1; see main.tf."
  default     = 1

  validation {
    condition     = var.min_nodes >= 1
    error_message = "min_nodes must be at least 1, or the ARC controller has no node to run on."
  }
}

variable "machine_type" {
  type        = string
  description = "Machine type of the runner nodes. n2-standard-4 matches a GitHub-hosted ubuntu-latest runner (4 vCPU, 16 GB). Must be x86_64."
  default     = "n2-standard-4"
}

variable "runner_cpu_request" {
  type        = string
  description = "CPU request of each runner pod. Keep it above half of a node's allocatable CPU so that only one runner fits on a node."
  default     = "3"
}

variable "runner_memory_request" {
  type        = string
  description = "Memory request of each runner pod. It must fit in a node's allocatable memory."
  default     = "10Gi"
}

variable "runner_image" {
  type        = string
  description = "Runner container image. The ARC chart default tracks latest because GitHub refuses connections from deprecated runner versions."
  default     = "ghcr.io/actions/actions-runner:latest"
}

variable "arc_version" {
  type        = string
  description = "Version of the ARC controller and runner scale set Helm charts. Both charts must use the same version."
  default     = "0.15.0"
}
