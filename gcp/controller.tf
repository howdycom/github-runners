locals {
  controller_env = {
    GCP_PROJECT            = var.project_id
    ZONES                  = join(",", var.zones)
    INSTANCE_TEMPLATE      = google_compute_instance_template.runner.id
    NAME_PREFIX            = var.name_prefix
    RUNNER_LABEL           = var.runner_label
    RUNNER_GROUP           = var.runner_group
    GITHUB_ORG             = var.github_org
    GITHUB_APP_ID          = var.github_app_id
    GITHUB_INSTALLATION_ID = var.github_app_installation_id
    REPOSITORIES           = join(",", var.repositories)
    MAX_VMS                = tostring(var.max_vms)
    IDLE_TIMEOUT_SECONDS   = tostring(var.idle_timeout_minutes * 60)
  }

  controller_secrets = {
    GITHUB_APP_PRIVATE_KEY = var.github_app_private_key_secret
    GITHUB_WEBHOOK_SECRET  = var.github_webhook_secret_secret
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

resource "google_project_iam_member" "controller_compute" {
  project = var.project_id
  role    = "roles/compute.instanceAdmin.v1"
  member  = google_service_account.controller.member
}

resource "google_secret_manager_secret_iam_member" "controller" {
  for_each = local.controller_secrets

  secret_id = each.value
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.controller.member
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

# Receives GitHub's workflow_job webhooks. It is reachable from the internet,
# because GitHub has to reach it; every request must carry a valid HMAC
# signature made with the webhook secret.
resource "google_cloudfunctions2_function" "webhook" {
  name     = "${var.name_prefix}-webhook"
  location = var.region

  build_config {
    runtime         = "python313"
    entry_point     = "webhook"
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
    timeout_seconds                = 30
    max_instance_count             = 10
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
    google_secret_manager_secret_iam_member.controller,
  ]
}

resource "google_cloud_run_v2_service_iam_member" "webhook_public" {
  name     = google_cloudfunctions2_function.webhook.service_config[0].service
  location = var.region
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# Cleans up finished and idle VMs and starts VMs for queued jobs whose webhook
# was lost. Only the scheduler's service account can call it. One instance
# at a time, so two passes never act on the same VM.
resource "google_cloudfunctions2_function" "reconcile" {
  name     = "${var.name_prefix}-reconcile"
  location = var.region

  build_config {
    runtime         = "python313"
    entry_point     = "reconcile"
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
    timeout_seconds                = 110
    max_instance_count             = 1
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
    google_secret_manager_secret_iam_member.controller,
  ]
}

resource "google_cloud_run_v2_service_iam_member" "reconcile_scheduler" {
  name     = google_cloudfunctions2_function.reconcile.service_config[0].service
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
    uri         = google_cloudfunctions2_function.reconcile.url

    oidc_token {
      service_account_email = google_service_account.scheduler.email
      audience              = google_cloudfunctions2_function.reconcile.url
    }
  }

  depends_on = [google_cloud_run_v2_service_iam_member.reconcile_scheduler]
}
