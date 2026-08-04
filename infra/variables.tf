variable "docker_host" {
  description = "Docker daemon socket to connect to"
  type        = string
  default     = "unix:///var/run/docker.sock"
}

variable "ssh_user" {
  description = "SSH user for a remote Docker host. Ignored when docker_host already embeds a user (ssh://user@host)."
  type        = string
  default     = ""
}

variable "enable_portainer" {
  description = "Enable Portainer stack deployment"
  type        = bool
  default     = true
}

variable "enable_github_runners" {
  description = "Enable GitHub Actions runner stack deployment"
  type        = bool
  default     = true
}

variable "github_runner_org_url" {
  description = "GitHub organization URL (e.g., https://github.com/my-org)"
  type        = string
  default     = ""
}

variable "github_runner_token" {
  description = "GitHub Actions runner registration token"
  type        = string
  default     = ""
  sensitive   = true
}

variable "github_runner_heavy_count" {
  description = "Number of heavy (Docker/build workload) runner containers to deploy"
  type        = number
  default     = 2
}

variable "github_runner_light_count" {
  description = "Number of light (CI job) runner containers to deploy"
  type        = number
  default     = 4
}

variable "github_runner_heavy_labels" {
  description = "Comma-separated labels for heavy runners"
  type        = string
  default     = "docker,ubuntu-22.04,heavy"
}

variable "github_runner_light_labels" {
  description = "Comma-separated labels for light runners"
  type        = string
  default     = "docker,ubuntu-22.04,light"
}

variable "github_runner_name_prefix" {
  description = "Prefix for runner names"
  type        = string
  default     = "github-runner"
}

variable "github_runner_version" {
  description = "GitHub Actions runner version to install"
  type        = string
  default     = "2.323.0"
}

variable "zram_size_mib" {
  description = "Size of the zRAM compressed swap device in MiB"
  type        = number
  default     = 8192
}

variable "swap_size_gib" {
  description = "Size of the on-disk swap file in GiB"
  type        = number
  default     = 16
}
