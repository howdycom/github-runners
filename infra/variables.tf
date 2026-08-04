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

variable "github_runner_pat" {
  description = "Optional GitHub credential with self-hosted runner RW permission on the org (or repo). Leave empty to use the local gh CLI's token (gh auth token) automatically — no copy/paste needed. Containers use it to mint short-lived registration/remove tokens at start/stop time."
  type        = string
  default     = ""
  sensitive   = true
}

variable "github_runner_ephemeral" {
  description = "Register runners with --ephemeral so each job gets a clean environment and GitHub auto-removes the runner record after a job"
  type        = bool
  default     = true
}

variable "github_runner_heavy_count" {
  description = "Number of heavy-tier (Docker/build workload) runner containers to deploy"
  type        = number
  default     = 2
}

variable "github_runner_light_count" {
  description = "Number of light-tier (lighter CI job) runner containers to deploy"
  type        = number
  default     = 8
}

variable "github_runner_heavy_labels" {
  description = "Comma-separated labels for heavy-tier runners"
  type        = string
  default     = "docker,ubuntu-22.04,heavy"
}

variable "github_runner_light_labels" {
  description = "Comma-separated labels for light-tier runners"
  type        = string
  default     = "docker,ubuntu-22.04,light"
}

variable "github_runner_heavy_cpus" {
  description = "CPU limit per heavy-tier runner container. Defaults to 4 to match a GitHub-hosted ubuntu-latest standard runner."
  type        = string
  default     = "4"
}

variable "github_runner_heavy_memory" {
  description = "Memory limit per heavy-tier runner container. 8g keeps this an enforceable cap on a 16 GB host; a hosted ubuntu-latest runner nominally gets 16 GB, but a limit above physical RAM is never actually applied."
  type        = string
  default     = "8g"
}

variable "github_runner_light_cpus" {
  description = "CPU limit per light-tier runner container"
  type        = string
  default     = "2"
}

variable "github_runner_light_memory" {
  description = "Memory limit per light-tier runner container"
  type        = string
  default     = "4g"
}

variable "github_runner_name_prefix" {
  description = "Prefix for runner names"
  type        = string
  default     = "github-runner"
}

variable "github_runner_version" {
  description = "GitHub Actions runner version to install"
  type        = string
  default     = "2.336.0"
}

variable "github_runner_registration_timeout" {
  description = "Seconds to wait for all runners to show up online in GitHub before failing the apply"
  type        = number
  default     = 900
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
