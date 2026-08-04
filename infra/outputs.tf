output "portainer_url" {
  description = "URL to access Portainer"
  value       = var.enable_portainer ? "http://${local.is_ssh ? local.ssh_host : "localhost"}:9000" : "Portainer not enabled"
}

output "github_runner_stack" {
  description = "GitHub Actions runner stack status"
  value       = var.enable_github_runners ? "github-runner" : "GitHub runners not enabled"
}

output "deployed_stacks" {
  description = "List of deployed stacks"
  value = concat(
    var.enable_portainer ? ["portainer"] : [],
    var.enable_github_runners ? ["github-runner"] : []
  )
}
