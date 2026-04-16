# StackRamp Platform Bootstrap
# Run ONCE per environment (dev / prod) to set up the shared platform project.
# After this, individual apps require NO terraform — they just push code.

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 7.0"
    }
  }
}

locals {
  platform_project = var.platform_project
  region           = var.region
}

provider "google" {
  project = local.platform_project
  region  = local.region
}

provider "google-beta" {
  project = local.platform_project
  region  = local.region
}

# ── APIs ──────────────────────────────────────────────────────────────────────

resource "google_project_service" "apis" {
  for_each = toset([
    "firebase.googleapis.com",
    "firebasehosting.googleapis.com",
    "run.googleapis.com",
    "artifactregistry.googleapis.com",
    "secretmanager.googleapis.com",
    "sqladmin.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "storage.googleapis.com",
    "cloudbuild.googleapis.com",
    "dns.googleapis.com",
    "compute.googleapis.com",
    "iap.googleapis.com",
    "servicenetworking.googleapis.com",
    "vpcaccess.googleapis.com",
  ])

  service            = each.value
  disable_on_destroy = false
}

# ── Firebase Project ──────────────────────────────────────────────────────────
# Enable Firebase on the GCP project — required before any Firebase resources can be created.

resource "google_firebase_project" "default" {
  provider   = google-beta
  project    = local.platform_project
  depends_on = [google_project_service.apis]
}

# ── Artifact Registry ─────────────────────────────────────────────────────────
# All apps share one registry: stackramp-images/<app-name>:<sha>

resource "google_artifact_registry_repository" "stackramp_images" {
  location      = local.region
  repository_id = "stackramp-images"
  format        = "DOCKER"
  description   = "StackRamp shared container registry"
  depends_on    = [google_project_service.apis]
}

# ── Platform CI/CD Service Account ───────────────────────────────────────────
# This SA is used by ALL apps' GitHub Actions — no per-app SA needed

resource "google_service_account" "platform_cicd" {
  account_id   = "stackramp-cicd-sa"
  display_name = "StackRamp Platform CI/CD"
  description  = "Shared SA for all app deployments via GitHub Actions"
}

resource "google_project_iam_member" "platform_roles" {
  for_each = toset([
    "roles/run.admin",
    "roles/artifactregistry.admin",
    "roles/firebase.admin",
    "roles/secretmanager.admin",
    "roles/iam.serviceAccountUser",
    "roles/cloudsql.admin",
    "roles/storage.admin",
    "roles/dns.admin",
    "roles/compute.loadBalancerAdmin",
    "roles/compute.networkAdmin",
    "roles/vpcaccess.admin",
    "roles/iap.admin",
  ])

  project = local.platform_project
  role    = each.value
  member  = "serviceAccount:${google_service_account.platform_cicd.email}"
}

# ── Workload Identity Federation ──────────────────────────────────────────────
# ONE pool for the whole platform — all repos in the org can use it

resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "stackramp-github-pool"
  display_name              = "StackRamp GitHub Actions"
  depends_on                = [google_project_service.apis]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-provider"

  attribute_mapping = {
    "google.subject"             = "assertion.sub"
    "attribute.repository"       = "assertion.repository"
    "attribute.repository_owner" = "assertion.repository_owner"
  }

  attribute_condition = "attribute.repository_owner == '${var.github_owner}'"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# ── Cloud DNS Zone ────────────────────────────────────────────────────────────
# Manages DNS for the platform base domain (e.g. stackramp.io).
# Set var.base_domain to enable. Leave empty to skip.
# Set var.create_dns_zone = false if the zone already exists (e.g. created by
# GCP domain registration) — StackRamp will look it up via a data source.

resource "google_dns_managed_zone" "platform" {
  count       = var.base_domain != "" && var.create_dns_zone ? 1 : 0
  name        = replace(var.base_domain, ".", "-")
  dns_name    = "${var.base_domain}."
  description = "StackRamp platform domain"
  depends_on  = [google_project_service.apis]
}

data "google_dns_managed_zone" "existing" {
  count   = var.base_domain != "" && !var.create_dns_zone ? 1 : 0
  name    = replace(var.base_domain, ".", "-")
  project = var.platform_project
}

locals {
  dns_zone_name        = var.base_domain != "" ? replace(var.base_domain, ".", "-") : ""
  dns_zone_nameservers = var.base_domain == "" ? [] : (var.create_dns_zone ? google_dns_managed_zone.platform[0].name_servers : data.google_dns_managed_zone.existing[0].name_servers)
}

data "google_project" "platform" {
  project_id = var.platform_project
  depends_on = [google_project_service.apis]
}

# ── Platform-Injectable Secrets ───────────────────────────────────────────────
# Platform team creates the secret shell here; values are set manually in the
# GCP Console. Any secret with the `platform-inject: true` label is automatically
# discovered and injected into every Cloud Run deployment via --set-secrets.

resource "google_secret_manager_secret" "platform" {
  for_each  = toset(var.platform_secrets)
  secret_id = each.value

  labels = {
    platform-inject = "true"
  }

  replication {
    auto {}
  }

  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_iam_member" "platform_run_access" {
  for_each  = toset(var.platform_secrets)
  secret_id = google_secret_manager_secret.platform[each.key].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${data.google_project.platform.number}-compute@developer.gserviceaccount.com"
}

# ── VPC Network (for Cloud SQL private IP) ───────────────────────────────────
# Cloud SQL with private IP requires a VPC with service networking peering.
# Cloud Run connects via a Serverless VPC Access Connector.

resource "google_compute_network" "platform" {
  count                           = var.enable_postgres ? 1 : 0
  name                            = "stackramp-vpc-${var.environment}"
  project                         = local.platform_project
  routing_mode                    = "GLOBAL"
  auto_create_subnetworks         = false
  delete_default_routes_on_create = false
  depends_on                      = [google_project_service.apis]
}

resource "google_compute_subnetwork" "platform" {
  count                    = var.enable_postgres ? 1 : 0
  name                     = "stackramp-subnet-${var.environment}"
  project                  = local.platform_project
  region                   = var.region
  network                  = google_compute_network.platform[0].name
  ip_cidr_range            = "10.0.0.0/20"
  private_ip_google_access = true
}

resource "google_compute_global_address" "private_ip_range" {
  count         = var.enable_postgres ? 1 : 0
  name          = "stackramp-sql-private-ip-${var.environment}"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.platform[0].id
}

resource "google_service_networking_connection" "private_vpc" {
  count                   = var.enable_postgres ? 1 : 0
  network                 = google_compute_network.platform[0].id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_range[0].name]
}

resource "google_vpc_access_connector" "platform" {
  count         = var.enable_postgres ? 1 : 0
  name          = "stackramp-vpc-${var.environment}"
  project       = local.platform_project
  region        = var.region
  network       = google_compute_network.platform[0].name
  ip_cidr_range = "10.8.0.0/28"
  min_instances = 2
  max_instances = 3
  depends_on    = [google_project_service.apis]
}

# ── Shared Cloud SQL Postgres Instance ────────────────────────────────────────
# One instance per environment, shared across all apps. Each app that declares
# `database: postgres` in stackramp.yaml gets its own database + user within
# this instance — no per-app instance cost.

resource "google_sql_database_instance" "platform" {
  count            = var.enable_postgres ? 1 : 0
  name             = "stackramp-postgres-${var.environment}"
  database_version = "POSTGRES_16"
  region           = var.region

  settings {
    tier    = var.postgres_tier
    edition = "ENTERPRISE"

    backup_configuration {
      enabled = true
    }

    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.platform[0].id
    }
  }

  deletion_protection = true
  depends_on          = [google_service_networking_connection.private_vpc]
}

resource "google_service_account_iam_member" "wif_binding" {
  service_account_id = google_service_account.platform_cicd.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository_owner/${var.github_owner}"
}

# ── IAP Secret Manager shells ─────────────────────────────────────────────────
# The IAP OAuth client is created manually in the GCP Console (APIs & Services
# → Credentials → OAuth 2.0 Client IDs). The google_iap_brand / google_iap_client
# Terraform resources are deprecated and shut down March 2026.
#
# After bootstrap apply:
# 1. GCP Console → APIs & Services → OAuth consent screen — configure if needed
# 2. GCP Console → APIs & Services → Credentials → Create OAuth 2.0 Client ID
#    (Web application, add no redirect URIs — IAP manages them)
# 3. Set the client ID and secret as secret versions in Secret Manager:
#    stackramp-iap-client-id   ← paste client ID
#    stackramp-iap-client-secret ← paste client secret

resource "google_secret_manager_secret" "iap_client_id" {
  count     = var.iap_allowed_domain != "" ? 1 : 0
  secret_id = "stackramp-iap-client-id"
  replication {
    auto {}
  }
  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret" "iap_client_secret" {
  count     = var.iap_allowed_domain != "" ? 1 : 0
  secret_id = "stackramp-iap-client-secret"
  replication {
    auto {}
  }
  depends_on = [google_project_service.apis]
}

# Grant the CICD SA access to read IAP credentials during app provisioning
resource "google_secret_manager_secret_iam_member" "iap_client_id_access" {
  count     = var.iap_allowed_domain != "" ? 1 : 0
  secret_id = google_secret_manager_secret.iap_client_id[0].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.platform_cicd.email}"
}

resource "google_secret_manager_secret_iam_member" "iap_client_secret_access" {
  count     = var.iap_allowed_domain != "" ? 1 : 0
  secret_id = google_secret_manager_secret.iap_client_secret[0].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.platform_cicd.email}"
}
