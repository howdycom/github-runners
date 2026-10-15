output "webhook_url" {
  description = "Set this as the GitHub App's webhook URL."
  value       = google_cloudfunctions2_function.webhook.url
}

output "runs_on" {
  description = "Value for a workflow's runs-on to select these runners."
  value       = ["self-hosted", var.runner_label]
}

output "instance_template" {
  description = "Instance template the controller creates runner VMs from."
  value       = google_compute_instance_template.runner.id
}

output "subnet" {
  description = "Runner subnet. bake-image.sh builds the VM image in it."
  value       = google_compute_subnetwork.runners.id
}
