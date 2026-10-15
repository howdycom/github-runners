resource "google_project_service" "required" {
  for_each = toset([
    "artifactregistry.googleapis.com",
    "cloudbuild.googleapis.com",
    "cloudfunctions.googleapis.com",
    "cloudscheduler.googleapis.com",
    "compute.googleapis.com",
    "iam.googleapis.com",
    "run.googleapis.com",
    "secretmanager.googleapis.com",
  ])

  service            = each.value
  disable_on_destroy = false
}

# A dedicated network: runner jobs execute pull request code, so this VPC has
# no peering or route to any other workload. There are no ingress firewall
# rules, so the implied deny-all ingress rule blocks every inbound connection.
resource "google_compute_network" "runners" {
  name                    = "${var.name_prefix}-network"
  auto_create_subnetworks = false

  depends_on = [google_project_service.required]
}

resource "google_compute_subnetwork" "runners" {
  name                     = "${var.name_prefix}-subnet"
  region                   = var.region
  network                  = google_compute_network.runners.id
  ip_cidr_range            = var.subnet_cidr
  private_ip_google_access = true
}

resource "google_compute_router" "runners" {
  count = var.use_cloud_nat ? 1 : 0

  name    = "${var.name_prefix}-router"
  region  = var.region
  network = google_compute_network.runners.id
}

resource "google_compute_router_nat" "runners" {
  count = var.use_cloud_nat ? 1 : 0

  name                               = "${var.name_prefix}-nat"
  router                             = google_compute_router.runners[0].name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}
