output "webhook_url" {
  description = "Set this as the GitHub App's webhook URL."
  value       = module.runners.webhook_url
}

output "runs_on" {
  description = "Value for a workflow's runs-on to select these runners."
  value       = module.runners.runs_on
}

output "subnet" {
  description = "Runner subnet. bake-image.sh can build the VM image in it."
  value       = module.runners.subnet
}
