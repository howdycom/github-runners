output "webhook_url" {
  description = "Set this as the GitHub App's webhook URL."
  value       = google_cloudfunctions2_function.controller["webhook"].url
}

output "runs_on" {
  description = "Value for a workflow's runs-on to select the standard runners."
  value       = ["self-hosted", var.runner_label]
}

output "heavy_runs_on" {
  description = "Value for a workflow's runs-on to select the heavy runners. Null when the heavy pool is off."
  value       = var.heavy_machine_type == null ? null : ["self-hosted", var.heavy_runner_label]
}

output "instance_template" {
  description = "Instance template the controller creates runner VMs from."
  value       = google_compute_instance_template.runner["standard"].id
}

output "subnet" {
  description = "Runner subnet. bake-image.sh builds the VM image in it."
  value       = google_compute_subnetwork.runners.id
}
