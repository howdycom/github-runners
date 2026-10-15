locals {
  required_services = [
    "compute.googleapis.com",
    "container.googleapis.com",
    "secretmanager.googleapis.com",
  ]

  pods_range_name     = "${var.subnet_name}-pods"
  services_range_name = "${var.subnet_name}-services"

  # Values for the ARC gha-runner-scale-set chart. With containerMode dind the
  # chart builds the pod itself and merges in the "runner" container below, so
  # image and command must be repeated here. The CPU request is sized so that
  # only one runner fits on each node; see runner_cpu_request.
  runner_values = {
    runnerScaleSetName = var.runner_scale_set_name
    runnerGroup        = var.runner_group
    minRunners         = 0
    maxRunners         = var.max_runners
    template = {
      spec = {
        containers = [
          {
            name    = "runner"
            image   = var.runner_image
            command = ["/home/runner/run.sh"]
            resources = {
              requests = {
                cpu    = var.runner_cpu_request
                memory = var.runner_memory_request
              }
            }
          },
        ]
      }
    }
  }
}

resource "google_project_service" "required" {
  for_each = toset(local.required_services)

  service            = each.value
  disable_on_destroy = false
}

# A dedicated network: runner jobs execute pull request code, so this VPC has
# no peering or route to any other workload.
resource "google_compute_network" "runners" {
  name                    = var.network_name
  auto_create_subnetworks = false

  depends_on = [google_project_service.required]
}

resource "google_compute_subnetwork" "runners" {
  name                     = var.subnet_name
  region                   = var.region
  network                  = google_compute_network.runners.id
  ip_cidr_range            = var.subnet_cidr
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = local.pods_range_name
    ip_cidr_range = var.pods_cidr
  }

  secondary_ip_range {
    range_name    = local.services_range_name
    ip_cidr_range = var.services_cidr
  }
}

# Nodes have no public IP, so they reach GitHub and the container registries
# through Cloud NAT.
resource "google_compute_router" "runners" {
  name    = "${var.network_name}-router"
  region  = var.region
  network = google_compute_network.runners.id
}

resource "google_compute_router_nat" "runners" {
  name                               = "${var.network_name}-nat"
  router                             = google_compute_router.runners.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# The App private key is read from Secret Manager at apply time instead of
# being passed on the command line. It still ends up in Terraform state (the
# module writes it to a Kubernetes secret), so the state bucket must be private.
data "google_secret_manager_secret_version" "github_app_private_key" {
  secret  = var.github_app_private_key_secret
  version = var.github_app_private_key_secret_version

  depends_on = [google_project_service.required]
}

module "runners" {
  source  = "terraform-google-modules/github-actions-runners/google//modules/gh-runner-gke"
  version = "5.1.0"

  project_id     = var.project_id
  region         = var.region
  zones          = [var.zone]
  cluster_suffix = var.cluster_suffix

  create_network         = false
  network_name           = google_compute_network.runners.name
  subnet_name            = google_compute_subnetwork.runners.name
  ip_range_pods_name     = local.pods_range_name
  ip_range_services_name = local.services_range_name
  enable_private_nodes   = true

  # The module creates a single node pool, and it waits for the ARC controller
  # to start. The controller needs a node, so the pool keeps min_nodes running.
  # That node also takes jobs. One node above max_runners covers the case where
  # the system pods on the first node leave too little room for a runner.
  machine_type   = var.machine_type
  min_node_count = var.min_nodes
  max_node_count = var.max_runners + 1

  gh_config_url          = var.github_config_url
  gh_app_id              = var.github_app_id
  gh_app_installation_id = var.github_app_installation_id
  gh_app_private_key     = data.google_secret_manager_secret_version.github_app_private_key.secret_data

  arc_controller_version = var.arc_version
  arc_runners_version    = var.arc_version
  arc_container_mode     = "dind"
  arc_runners_values     = [yamlencode(local.runner_values)]

  depends_on = [google_compute_router_nat.runners]
}
