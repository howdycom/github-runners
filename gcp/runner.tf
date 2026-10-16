locals {
  # The image bake-image.sh builds, unless var.source_image overrides it.
  source_image = coalesce(var.source_image, "projects/${var.project_id}/global/images/family/github-runner")
  # A second family, so rebuilding the standard image does not change heavy VMs.
  heavy_source_image = "projects/${var.project_id}/global/images/family/github-runner-heavy"
  heavy_disk_size_gb = coalesce(var.heavy_disk_size_gb, var.disk_size_gb)

  # The controller filters on these labels, so it only ever touches its own VMs.
  # Heavy VMs also carry ghr_class = "heavy", which splits the two caps. A VM
  # without ghr_class counts as standard.
  runner_vm_labels = {
    ghr_managed = "true"
    ghr_pool    = var.name_prefix
  }

  # One instance template per pool. The heavy entry exists only when
  # heavy_machine_type is set, so an apply does not require the heavy image
  # family until you opt in.
  runner_templates = {
    for pool, template in {
      standard = {
        name_prefix  = "${var.name_prefix}-runner-"
        machine_type = var.machine_type
        labels       = local.runner_vm_labels
        source_image = local.source_image
        disk_size_gb = var.disk_size_gb
      }
      # Same image contents as the standard template, on a larger machine type.
      heavy = {
        name_prefix  = "${var.name_prefix}-heavy-"
        machine_type = var.heavy_machine_type
        labels       = merge(local.runner_vm_labels, { ghr_class = "heavy" })
        source_image = local.heavy_source_image
        disk_size_gb = local.heavy_disk_size_gb
      }
    } : pool => template if pool != "heavy" || var.heavy_machine_type != null
  }
}

# The controller creates one VM per job from this template and adds the job's
# one-time runner config as metadata. Templates are immutable, so a change
# creates a new template and the controller switches to it on its next deploy.
resource "google_compute_instance_template" "runner" {
  for_each = local.runner_templates

  name_prefix  = each.value.name_prefix
  machine_type = each.value.machine_type
  labels       = each.value.labels

  disk {
    boot         = true
    auto_delete  = true
    source_image = each.value.source_image
    disk_type    = var.disk_type
    disk_size_gb = each.value.disk_size_gb
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

    # A failed check block only warns. The controller refuses one label for
    # both pools, so stop the apply here instead.
    precondition {
      condition     = each.key != "heavy" || var.heavy_runner_label != var.runner_label
      error_message = "heavy_runner_label must differ from runner_label, or a heavy VM can take a standard job."
    }
  }

  depends_on = [google_project_service.required]
}

# The standard template had no for_each before the heavy pool. This keeps
# existing deploys from replacing it.
moved {
  from = google_compute_instance_template.runner
  to   = google_compute_instance_template.runner["standard"]
}
