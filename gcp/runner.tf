locals {
  # The controller filters on these labels, so it only ever touches its own VMs.
  runner_vm_labels = {
    ghr_managed = "true"
    ghr_pool    = var.name_prefix
  }
}

# The controller creates one VM per job from this template and adds the job's
# one-time runner config as metadata. Templates are immutable, so a change
# creates a new template and the controller switches to it on its next deploy.
resource "google_compute_instance_template" "runner" {
  name_prefix  = "${var.name_prefix}-runner-"
  machine_type = var.machine_type
  labels       = local.runner_vm_labels

  disk {
    boot         = true
    auto_delete  = true
    source_image = var.source_image
    disk_type    = "pd-balanced"
    disk_size_gb = var.disk_size_gb
  }

  network_interface {
    subnetwork = google_compute_subnetwork.runners.id

    # Ephemeral public IP for egress, unless Cloud NAT is used.
    dynamic "access_config" {
      for_each = var.use_cloud_nat ? [] : [1]
      content {}
    }
  }

  # No service_account block: the VM gets no service account, so job code
  # cannot obtain a GCP access token from the metadata server.

  metadata = {
    startup-script         = file("${path.module}/runner/startup.sh")
    runner-version         = var.runner_version
    runner-sha256          = var.runner_sha256
    block-project-ssh-keys = "TRUE"
    enable-oslogin         = "TRUE"
  }

  scheduling {
    automatic_restart           = false
    on_host_maintenance         = "MIGRATE"
    provisioning_model          = "STANDARD"
    instance_termination_action = "DELETE"

    # Hard limit: Compute Engine deletes the VM after this, whatever happens
    # to the job or the controller.
    max_run_duration {
      seconds = var.max_vm_lifetime_hours * 3600
    }
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [google_project_service.required]
}
