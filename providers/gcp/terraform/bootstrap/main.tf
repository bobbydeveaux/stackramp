# Launchpad Platform Bootstrap
# Run ONCE per environment (dev / prod) to set up the shared platform project.
# After this, individual apps require NO terraform — they just push code.

locals {
  platform_project = var.platform_project
  region           = var.region
}

provider "google" {
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
  ])

  service            = each.value
  disable_on_destroy = false
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

resource "google_service_account_iam_member" "wif_binding" {
  service_account_id = google_service_account.platform_cicd.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository_owner/${var.github_owner}"
}

# ── Terraform State Bucket ────────────────────────────────────────────────────

resource "google_storage_bucket" "tf_state" {
  name          = "${local.platform_project}-tf-state"
  location      = local.region
  force_destroy = false

  versioning {
    enabled = true
  }

  uniform_bucket_level_access = true
}
