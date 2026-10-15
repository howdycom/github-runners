variable "project_id" {
  type        = string
  description = "GCP project for the runners. Use a project dedicated to CI."
}

variable "region" {
  type        = string
  description = "GCP region for the network, the controller and the runner VMs."
  default     = "us-central1"
}

variable "zones" {
  type        = list(string)
  description = "Zones the controller may create runner VMs in, all in var.region. When a zone has no capacity, the controller tries the next one."
  default     = ["us-central1-a", "us-central1-b", "us-central1-c", "us-central1-f"]

  validation {
    condition     = length(var.zones) > 0
    error_message = "Set at least one zone."
  }
}

variable "name_prefix" {
  type        = string
  description = "Prefix for resource names, runner VM names and GitHub runner names. Runner VMs are named <prefix>-<job id>."
  default     = "ghr"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,19}$", var.name_prefix))
    error_message = "Use 1-20 lowercase letters, digits or hyphens, starting with a letter."
  }
}

variable "subnet_cidr" {
  type        = string
  description = "Primary range of the runner subnet."
  default     = "10.10.0.0/20"
}

variable "use_cloud_nat" {
  type        = bool
  description = "Reach the internet through Cloud NAT instead of an ephemeral public IP per VM. Required when the organization policy constraints/compute.vmExternalIpAccess forbids external IPs; without it the controller cannot create runner VMs there. Either way, VMs accept no inbound traffic. See README.md#network."
  default     = false
}

variable "machine_type" {
  type        = string
  description = "Machine type of the runner VMs. n2d-standard-2 (2 vCPU, 8 GB) matches a GitHub-hosted runner for private repositories. Must be x86_64."
  default     = "n2d-standard-2"
}

variable "disk_size_gb" {
  type        = number
  description = "Boot disk size of each runner VM, in GB (pd-balanced)."
  default     = 75
}

variable "source_image" {
  type        = string
  description = "Boot image for runner VMs. Defaults to the github-runner image family in var.project_id, built by bake-image.sh with Docker and the runner preinstalled. Build it before the first apply."
  default     = null
}

variable "runner_version" {
  type        = string
  description = "GitHub Actions runner version installed at boot or bake time. The runner updates itself when GitHub requires a newer version."
  default     = "2.337.0"
}

variable "runner_sha256" {
  type        = string
  description = "SHA-256 of actions-runner-linux-x64-<runner_version>.tar.gz, from the runner's release notes. Change it together with runner_version."
  default     = "70920811a4f8ad4328818682bca5c6469c1c942fab52448868071d0063816613"

  validation {
    condition     = can(regex("^[0-9a-f]{64}$", var.runner_sha256))
    error_message = "Use the 64-character lowercase hex SHA-256."
  }
}

variable "runner_label" {
  type        = string
  description = "Custom runner label. Workflows select these runners with runs-on: [self-hosted, <label>]."
  default     = "gcp-x64"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,62}$", var.runner_label))
    error_message = "Use lowercase letters, digits or hyphens."
  }
}

variable "max_vms" {
  type        = number
  description = "Maximum number of runner VMs at once. Check the regional CPU quota against max_vms times the machine's vCPUs."
  default     = 20

  validation {
    condition     = var.max_vms >= 1
    error_message = "max_vms must be at least 1."
  }
}

variable "idle_timeout_minutes" {
  type        = number
  description = "A VM whose runner has not taken a job after this many minutes powers itself off, and the controller deletes it. This happens, for example, when the job was cancelled while the VM booted."
  default     = 15
}

variable "max_vm_lifetime_hours" {
  type        = number
  description = "Compute Engine deletes any runner VM after this many hours. Keep it above the longest job timeout."
  default     = 3

  validation {
    condition     = var.max_vm_lifetime_hours >= 1 && var.max_vm_lifetime_hours <= 24
    error_message = "Use 1 to 24 hours."
  }
}

variable "github_org" {
  type        = string
  description = "GitHub organization the runners register to."
}

variable "github_app_id" {
  type        = string
  description = "App ID of the GitHub App."
}

variable "github_app_installation_id" {
  type        = string
  description = "Installation ID of the GitHub App in the organization."
}

variable "github_app_private_key_secret" {
  type        = string
  description = "Secret Manager secret ID (in var.project_id) holding the GitHub App private key (PEM)."
}

variable "github_webhook_secret_id" {
  type        = string
  description = "Secret Manager secret ID (in var.project_id) holding the GitHub App webhook secret."
}

variable "runner_group" {
  type        = string
  description = "GitHub runner group for the runners. The controller refuses to register runners if the group allows public repositories."

  validation {
    condition     = length(trimspace(var.runner_group)) > 0 && lower(var.runner_group) != "default"
    error_message = "Set a dedicated runner group. The Default group can be shared with every repository in the organization."
  }
}

variable "repositories" {
  type        = list(string)
  description = "Names (without the organization) of the repositories that use these runners. The reconcile job scans them for queued jobs without a VM, for example after a lost webhook or a full pool."

  validation {
    condition     = length(var.repositories) > 0
    error_message = "List at least one repository. Without it, a job the webhook could not start a VM for stays queued."
  }
}
