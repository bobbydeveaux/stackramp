# Launchpad Platform Bootstrap
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
# All apps share one registry: launchpad-images/<app-name>:<sha>

resource "google_artifact_registry_repository" "launchpad_images" {
  location      = local.region
  repository_id = "launchpad-images"
  format        = "DOCKER"
  description   = "Launchpad shared container registry"
  depends_on    = [google_project_service.apis]
}

# ── Platform CI/CD Service Account ───────────────────────────────────────────
# This SA is used by ALL apps' GitHub Actions — no per-app SA needed

resource "google_service_account" "platform_cicd" {
  account_id   = "launchpad-cicd-sa"
  display_name = "Launchpad Platform CI/CD"
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
  ])

  project = local.platform_project
  role    = each.value
  member  = "serviceAccount:${google_service_account.platform_cicd.email}"
}

# ── Workload Identity Federation ──────────────────────────────────────────────
# ONE pool for the whole platform — all repos in the org can use it

resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "launchpad-github-pool"
  display_name              = "Launchpad GitHub Actions"
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

resource "google_dns_managed_zone" "platform" {
  count       = var.base_domain != "" ? 1 : 0
  name        = replace(var.base_domain, ".", "-")
  dns_name    = "${var.base_domain}."
  description = "StackRamp platform domain"
  depends_on  = [google_project_service.apis]
}

resource "google_service_account_iam_member" "wif_binding" {
  service_account_id = google_service_account.platform_cicd.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository_owner/${var.github_owner}"
}
