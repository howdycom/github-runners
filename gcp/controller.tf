locals {
  controller_env = {
    GCP_PROJECT             = var.project_id
    ZONES                   = join(",", var.zones)
    INSTANCE_TEMPLATE       = google_compute_instance_template.runner["standard"].id
    HEAVY_INSTANCE_TEMPLATE = try(google_compute_instance_template.runner["heavy"].id, "")
    # In the order of heavy_fallback_machine_types: the controller tries them in turn.
    HEAVY_FALLBACK_INSTANCE_TEMPLATES = join(",", [
      for type in var.heavy_fallback_machine_types : google_compute_instance_template.runner["heavy-${type}"].id
      if var.heavy_machine_type != null
    ])
    HEAVY_RUNNER_LABEL     = var.heavy_runner_label
    MAX_HEAVY_VMS          = tostring(var.max_heavy_vms)
    NAME_PREFIX            = var.name_prefix
    RUNNER_LABEL           = var.runner_label
    RUNNER_GROUP           = var.runner_group
    GITHUB_ORG             = var.github_org
    GITHUB_APP_ID          = var.github_app_id
    GITHUB_INSTALLATION_ID = var.github_app_installation_id
    REPOSITORIES           = join(",", var.repositories)
    MAX_VMS                = tostring(var.max_vms)
    IDLE_TIMEOUT_SECONDS   = tostring(var.idle_timeout_minutes * 60)
    LOCK_BUCKET            = google_storage_bucket.locks.name
  }

  controller_secrets = {
    GITHUB_APP_PRIVATE_KEY = var.github_app_private_key_secret
    GITHUB_WEBHOOK_SECRET  = var.github_webhook_secret_id
  }
}

# --- Identities -------------------------------------------------------------

# Runs both functions. It creates and deletes runner VMs and reads the two
# GitHub secrets. Runner VMs have no service account, so it never needs
# iam.serviceAccounts.actAs.
resource "google_service_account" "controller" {
  account_id   = "${var.name_prefix}-controller"
  display_name = "GitHub runner controller"

  depends_on = [google_project_service.required]
}

# Only what the controller calls. A predefined role such as
# roles/compute.instanceAdmin.v1 would also let it manage instance groups, whose
# VMs the instance-group service agent creates outside the condition below.
resource "google_project_iam_custom_role" "controller_compute" {
  role_id     = "${replace(var.name_prefix, "-", "_")}_runner_controller"
  title       = "GitHub runner controller (${var.name_prefix})"
  description = "Creates and deletes the GitHub runner VMs of the ${var.name_prefix} stack."
  permissions = [
    "compute.disks.create",
    "compute.disks.delete", # the boot disk is auto-deleted with its VM
    "compute.images.useReadOnly",
    "compute.instanceTemplates.get",
    "compute.instanceTemplates.useReadOnly",
    "compute.instances.create",
    "compute.instances.delete",
    "compute.instances.get",
    "compute.instances.list",
    "compute.instances.setLabels",
    "compute.instances.setMetadata",
    "compute.subnetworks.use",
    "compute.subnetworks.useExternalIp",
    "compute.zoneOperations.get",
  ]

  depends_on = [google_project_service.required]
}

resource "google_project_iam_member" "controller_compute" {
  project = var.project_id
  role    = google_project_iam_custom_role.controller_compute.id
  member  = google_service_account.controller.member

  # For instances and disks, only the runner VMs (<prefix>-<job id>) and their
  # boot disks, which share the VM's name. The other resources in the role
  # (the template, the subnetwork, images, operations and project-level list
  # calls) are other types, so the first clause allows them.
  condition {
    title       = "${var.name_prefix} runner VMs only"
    description = "Instances and disks named ${var.name_prefix}-*"
    expression  = <<-EOT
      (resource.type != "compute.googleapis.com/Instance" && resource.type != "compute.googleapis.com/Disk")
      || resource.name.extract("/instances/{name}").startsWith("${var.name_prefix}-")
      || resource.name.extract("/disks/{name}").startsWith("${var.name_prefix}-")
    EOT
  }
}

resource "google_secret_manager_secret_iam_member" "controller" {
  for_each = local.controller_secrets

  secret_id = each.value
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.controller.member
}

# Holds the lock object that function instances take between checking the
# VM count and creating a VM, so concurrent webhooks cannot exceed max_vms.
resource "google_storage_bucket" "locks" {
  name                        = "${var.project_id}-${var.name_prefix}-locks"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = true

  depends_on = [google_project_service.required]
}

resource "google_storage_bucket_iam_member" "controller_locks" {
  bucket = google_storage_bucket.locks.name
  role   = "roles/storage.objectUser"
  member = google_service_account.controller.member
}

# Builds the function source. A dedicated account avoids depending on the
# project's default compute service account.
resource "google_service_account" "build" {
  account_id   = "${var.name_prefix}-build"
  display_name = "GitHub runner controller build"

  depends_on = [google_project_service.required]
}

resource "google_project_iam_member" "build" {
  for_each = toset([
    "roles/artifactregistry.writer",
    "roles/logging.logWriter",
  ])

  project = var.project_id
  role    = each.value
  member  = google_service_account.build.member
}

# Calls the reconcile function on a schedule.
resource "google_service_account" "scheduler" {
  account_id   = "${var.name_prefix}-scheduler"
  display_name = "GitHub runner reconcile scheduler"

  depends_on = [google_project_service.required]
}

# --- Function source --------------------------------------------------------

resource "google_storage_bucket" "source" {
  name                        = "${var.project_id}-${var.name_prefix}-source"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = true

  lifecycle_rule {
    condition {
      age = 30
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [google_project_service.required]
}

resource "google_storage_bucket_iam_member" "build_source" {
  bucket = google_storage_bucket.source.name
  role   = "roles/storage.objectViewer"
  member = google_service_account.build.member
}

# Cloud Run functions copy the source into their own staging bucket,
# gcf-v2-sources-<project number>-<region>, and the build reads it from there.
# Google creates that bucket with the first function, so the grant is
# project-level with a condition instead of on the bucket. The condition keeps
# the build account away from every other bucket, such as Terraform state.
resource "google_project_iam_member" "build_function_sources" {
  project = var.project_id
  role    = "roles/storage.objectViewer"
  member  = google_service_account.build.member

  condition {
    title       = "Cloud Run functions source buckets only"
    description = "Buckets named gcf-v2-sources-*"
    expression  = "resource.name.startsWith(\"projects/_/buckets/gcf-v2-sources-\")"
  }
}

data "archive_file" "controller" {
  type        = "zip"
  source_dir  = "${path.module}/controller"
  output_path = "${path.module}/.build/controller.zip"
  excludes    = ["tests", "requirements-dev.txt", ".pytest_cache", "ghr/__pycache__", "__pycache__"]
}

resource "google_storage_bucket_object" "controller" {
  name   = "controller-${data.archive_file.controller.output_sha256}.zip"
  bucket = google_storage_bucket.source.name
  source = data.archive_file.controller.output_path
}

# --- Functions --------------------------------------------------------------

locals {
  # Both functions run the same source and settings. The key is the entry point.
  controller_functions = {
    # Receives GitHub's workflow_job webhooks. It is reachable from the
    # internet, because GitHub has to reach it; every request must carry a
    # valid HMAC signature made with the webhook secret.
    webhook = {
      timeout_seconds    = 30
      max_instance_count = 10
    }
    # Cleans up finished and idle VMs and starts VMs for queued jobs whose
    # webhook was lost. Only the scheduler's service account can call it. One
    # instance at a time, so two passes never act on the same VM.
    reconcile = {
      timeout_seconds    = 110
      max_instance_count = 1
    }
  }
}

resource "google_cloudfunctions2_function" "controller" {
  for_each = local.controller_functions

  name     = "${var.name_prefix}-${each.key}"
  location = var.region

  build_config {
    runtime         = "python313"
    entry_point     = each.key
    service_account = google_service_account.build.id

    source {
      storage_source {
        bucket = google_storage_bucket.source.name
        object = google_storage_bucket_object.controller.name
      }
    }
  }

  service_config {
    service_account_email          = google_service_account.controller.email
    available_memory               = "256M"
    timeout_seconds                = each.value.timeout_seconds
    max_instance_count             = each.value.max_instance_count
    ingress_settings               = "ALLOW_ALL"
    all_traffic_on_latest_revision = true
    environment_variables          = local.controller_env

    dynamic "secret_environment_variables" {
      for_each = local.controller_secrets
      content {
        key        = secret_environment_variables.key
        project_id = var.project_id
        secret     = secret_environment_variables.value
        version    = "latest"
      }
    }
  }

  depends_on = [
    google_project_iam_member.build,
    google_storage_bucket_iam_member.build_source,
    google_project_iam_member.build_function_sources,
    google_secret_manager_secret_iam_member.controller,
    google_storage_bucket_iam_member.controller_locks,
  ]
}

resource "google_cloud_run_v2_service_iam_member" "webhook_public" {
  name     = google_cloudfunctions2_function.controller["webhook"].service_config[0].service
  location = var.region
  role     = "roles/run.invoker"
  member   = "allUsers"
}

resource "google_cloud_run_v2_service_iam_member" "reconcile_scheduler" {
  name     = google_cloudfunctions2_function.controller["reconcile"].service_config[0].service
  location = var.region
  role     = "roles/run.invoker"
  member   = google_service_account.scheduler.member
}

resource "google_cloud_scheduler_job" "reconcile" {
  name             = "${var.name_prefix}-reconcile"
  region           = var.region
  schedule         = "*/2 * * * *"
  attempt_deadline = "120s"

  retry_config {
    retry_count = 0
  }

  http_target {
    http_method = "POST"
    uri         = google_cloudfunctions2_function.controller["reconcile"].url

    oidc_token {
      service_account_email = google_service_account.scheduler.email
      audience              = google_cloudfunctions2_function.controller["reconcile"].url
    }
  }

  depends_on = [google_cloud_run_v2_service_iam_member.reconcile_scheduler]
}
