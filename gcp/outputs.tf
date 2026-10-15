output "cluster_name" {
  description = "Name of the runner cluster."
  value       = module.runners.cluster_name
}

output "location" {
  description = "Location of the runner cluster."
  value       = module.runners.location
}

output "runs_on" {
  description = "Value to use in a workflow's runs-on to select these runners."
  value       = var.runner_scale_set_name
}
