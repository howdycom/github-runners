locals {
  # The image bake-image.sh builds, unless var.source_image overrides it.
  source_image = coalesce(var.source_image, "projects/${var.project_id}/global/images/family/github-runner")
  # A second family, so rebuilding the standard image does not change heavy VMs.
  heavy_source_image = coalesce(var.heavy_source_image, "projects/${var.project_id}/global/images/family/github-runner-heavy")
  heavy_disk_size_gb = coalesce(var.heavy_disk_size_gb, var.disk_size_gb)

  # The controller filters on these labels, so it only ever touches its own VMs.
  # ghr_class splits the two caps. A VM from before this label counts as light.
  runner_vm_labels = {
    ghr_managed = "true"
    ghr_pool    = var.name_prefix
    ghr_class   = "light"
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
    source_image = local.source_image
    disk_type    = var.disk_type
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
    idle-timeout-seconds   = tostring(var.idle_timeout_minutes * 60)
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

# Same image contents as the standard template, on a larger machine type.
# Created only when heavy_machine_type is set, so an apply does not require
# the heavy image family until you opt in.
resource "google_compute_instance_template" "heavy" {
  count = var.heavy_machine_type == null ? 0 : 1

  name_prefix  = "${var.name_prefix}-heavy-"
  machine_type = var.heavy_machine_type
  labels = {
    ghr_managed = "true"
    ghr_pool    = var.name_prefix
    ghr_class   = "heavy"
  }

  disk {
    boot         = true
    auto_delete  = true
    source_image = local.heavy_source_image
    disk_type    = var.disk_type
    disk_size_gb = local.heavy_disk_size_gb
  }

  network_interface {
    subnetwork = google_compute_subnetwork.runners.id

    dynamic "access_config" {
      for_each = var.use_cloud_nat ? [] : [1]
      content {}
    }
  }

  metadata = {
    startup-script         = file("${path.module}/runner/startup.sh")
    runner-version         = var.runner_version
    runner-sha256          = var.runner_sha256
    idle-timeout-seconds   = tostring(var.idle_timeout_minutes * 60)
    block-project-ssh-keys = "TRUE"
    enable-oslogin         = "TRUE"
  }

  scheduling {
    automatic_restart           = false
    on_host_maintenance         = "MIGRATE"
    provisioning_model          = "STANDARD"
    instance_termination_action = "DELETE"

    max_run_duration {
      seconds = var.max_vm_lifetime_hours * 3600
    }
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [google_project_service.required]
}
