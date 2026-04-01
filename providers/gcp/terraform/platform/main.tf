# StackRamp Per-App Infrastructure
# Run idempotently on every deploy to ensure app infra exists.
# Creates Firebase Hosting site + Cloud Run service for the app.

provider "google" {
  project = var.platform_project
  region  = var.region
}

provider "google-beta" {
  project = var.platform_project
  region  = var.region
}

# ── Firebase Hosting Site ─────────────────────────────────────────────────────

resource "google_firebase_hosting_site" "app" {
  provider = google-beta
  project  = var.platform_project
  site_id  = "${var.app_name}-${var.environment}"
}

# ── Custom Domain ─────────────────────────────────────────────────────────────

resource "google_firebase_hosting_custom_domain" "app" {
  count        = var.custom_domain != "" ? 1 : 0
  provider     = google-beta
  project      = var.platform_project
  site_id      = google_firebase_hosting_site.app.site_id
  custom_domain = var.custom_domain
}

# ── Cloud DNS records (if a managed zone is provided) ─────────────────────────
# Firebase populates required_dns_updates with TXT (ownership verification) and
# A records. Since Cloud DNS is authoritative, Terraform injects them directly —
# Firebase polls Cloud DNS, finds the TXT, auto-verifies, and starts serving.
# Records are only created once Firebase has returned non-empty rrdatas, so the
# first apply (TXT only) and subsequent applies (TXT + A) are both safe.

locals {
  dns_enabled = var.custom_domain != "" && var.dns_zone_name != ""

  # Firebase Hosting uses stable load-balancer IPs — these do not change per-site.
  # We hardcode them so the A record is never destroyed once created, even after
  # Firebase considers verification complete and required_dns_updates goes empty.
  firebase_a_records = ["199.36.158.100", "199.36.158.101"]

  # TXT records are only needed during domain ownership verification.
  # Once Firebase verifies, required_dns_updates goes empty and we remove them.
  txt_records = local.dns_enabled ? flatten([
    for update in google_firebase_hosting_custom_domain.app[0].required_dns_updates : [
      for desired in update.desired : [
        for record in desired.records : record.rdata
        if record.type == "TXT"
      ]
    ]
  ]) : []
}

resource "google_dns_record_set" "frontend_a" {
  count        = local.dns_enabled ? 1 : 0
  name         = "${var.custom_domain}."
  type         = "A"
  ttl          = 300
  managed_zone = var.dns_zone_name
  project      = var.platform_project
  rrdatas      = local.firebase_a_records
}

resource "google_dns_record_set" "frontend_txt" {
  count        = local.dns_enabled && length(local.txt_records) > 0 ? 1 : 0
  name         = "${var.custom_domain}."
  type         = "TXT"
  ttl          = 300
  managed_zone = var.dns_zone_name
  project      = var.platform_project
  rrdatas      = local.txt_records
}

# ── Cloud Run Service ─────────────────────────────────────────────────────────
# Creates the service shell — actual deployment is done by the workflow

resource "google_cloud_run_v2_service" "app" {
  name                = "${var.app_name}-${var.environment}"
  location            = var.region
  project             = var.platform_project
  deletion_protection = false

  template {
    containers {
      image = "us-docker.pkg.dev/cloudrun/container/hello"

      env {
        name  = "ENVIRONMENT"
        value = var.environment
      }
      env {
        name  = "APP_NAME"
        value = var.app_name
      }
    }
  }

  lifecycle {
    ignore_changes = [
      template[0].containers[0].image,
      template[0].containers[0].env,
    ]
  }
}

# Allow unauthenticated access
resource "google_cloud_run_v2_service_iam_member" "public" {
  project  = var.platform_project
  location = var.region
  name     = google_cloud_run_v2_service.app.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# ── Backend Custom Domain ──────────────────────────────────────────────────────
# Maps api.{custom_domain} to the Cloud Run service.
# Pattern: api.stackramp.io / api.guardian.stackramp.io / api.guardian.dev.stackramp.io

resource "google_cloud_run_domain_mapping" "api" {
  count    = var.backend_domain != "" ? 1 : 0
  location = var.region
  name     = var.backend_domain

  metadata {
    namespace = var.platform_project
  }

  spec {
    route_name = google_cloud_run_v2_service.app.name
  }
}

resource "google_dns_record_set" "api_cname" {
  count        = var.backend_domain != "" && var.dns_zone_name != "" ? 1 : 0
  name         = "${var.backend_domain}."
  type         = "CNAME"
  ttl          = 300
  managed_zone = var.dns_zone_name
  project      = var.platform_project
  rrdatas      = ["ghs.googlehosted.com."]
}
