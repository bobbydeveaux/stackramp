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

provider "random" {}

# ── Firebase Hosting Site ─────────────────────────────────────────────────────
# Firebase site IDs are globally unique. A random suffix avoids collisions
# with other projects or previously deleted sites (30-day hold after deletion).
# ignore_changes = [site_id] ensures existing sites are never recreated —
# only new sites get the suffix stamped at first creation.

resource "random_string" "site_suffix" {
  length  = 5
  special = false
  upper   = false
}

resource "google_firebase_hosting_site" "app" {
  provider = google-beta
  project  = var.platform_project
  site_id  = "${var.app_name}-${random_string.site_suffix.result}-${var.environment}"

  lifecycle {
    ignore_changes = [site_id]
  }
}

# ── Custom Domain ─────────────────────────────────────────────────────────────

resource "google_firebase_hosting_custom_domain" "app" {
  count         = var.custom_domain != "" ? 1 : 0
  provider      = google-beta
  project       = var.platform_project
  site_id       = google_firebase_hosting_site.app.site_id
  custom_domain = var.custom_domain
}

# ── Cloud DNS records (if a managed zone is provided) ─────────────────────────
# Firebase populates required_dns_updates with TXT (ownership verification) and
# A records. Since Cloud DNS is authoritative, Terraform injects them directly —
# Firebase polls Cloud DNS, finds the TXT, auto-verifies, and starts serving.
# Records are only created once Firebase has returned non-empty rrdatas, so the
# first apply (TXT only) and subsequent applies (TXT + A) are both safe.

locals {
  dns_enabled          = var.custom_domain != "" && var.dns_zone_name != ""
  cloudsql_instance_id = var.has_database && var.cloudsql_connection_name != "" ? split(":", var.cloudsql_connection_name)[2] : ""
  # Apex domains (e.g. stackramp.io) cannot use CNAME — use A records.
  # Subdomains (e.g. guardian.stackramp.io) use CNAME to the Firebase site's
  # .web.app URL so Firebase can verify ownership and issue SSL automatically.
  is_subdomain = local.dns_enabled && length(split(".", var.custom_domain)) > 2

  firebase_a_records = ["199.36.158.100", "199.36.158.101"]
}

# Apex domain: A records pointing at Firebase's stable load-balancer IPs
resource "google_dns_record_set" "frontend_a" {
  count        = local.dns_enabled && !local.is_subdomain ? 1 : 0
  name         = "${var.custom_domain}."
  type         = "A"
  ttl          = 300
  managed_zone = var.dns_zone_name
  project      = var.platform_project
  rrdatas      = local.firebase_a_records
}

# Subdomain: CNAME to the Firebase Hosting site — Firebase verifies ownership
# and issues SSL via the web.app domain it already controls
resource "google_dns_record_set" "frontend_cname" {
  count        = local.is_subdomain ? 1 : 0
  name         = "${var.custom_domain}."
  type         = "CNAME"
  ttl          = 300
  managed_zone = var.dns_zone_name
  project      = var.platform_project
  rrdatas      = ["${google_firebase_hosting_site.app.site_id}.web.app."]
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

# ── GCS Data Bucket (optional) ────────────────────────────────────────────────
# When storage: gcs is declared in stackramp.yaml, provisions a persistent
# data bucket and grants the Cloud Run service account access.

data "google_project" "project" {
  project_id = var.platform_project
}

resource "google_storage_bucket" "app_data" {
  count         = var.has_storage ? 1 : 0
  name          = "${var.app_name}-data-${var.environment}"
  project       = var.platform_project
  location      = var.region
  force_destroy = false

  uniform_bucket_level_access = true

  lifecycle {
    prevent_destroy = false
  }
}

# Grant Cloud Run service account (default compute SA) objectAdmin on the bucket
resource "google_storage_bucket_iam_member" "app_data_run" {
  count  = var.has_storage ? 1 : 0
  bucket = google_storage_bucket.app_data[0].name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${data.google_project.project.number}-compute@developer.gserviceaccount.com"
}

# ── Per-App Postgres Database (optional) ─────────────────────────────────────
# Creates a database + user within the shared Cloud SQL instance provisioned
# by bootstrap. Generates a random password and stores the full DATABASE_URL
# in Secret Manager so it is mounted directly into Cloud Run — the password
# never appears in workflow logs.

resource "random_password" "db" {
  count   = var.has_database ? 1 : 0
  length  = 32
  special = false
}

resource "google_sql_database" "app" {
  count    = var.has_database ? 1 : 0
  name     = "${var.app_name}_${var.environment}"
  instance = local.cloudsql_instance_id
}

resource "google_sql_user" "app" {
  count    = var.has_database ? 1 : 0
  name     = "${var.app_name}_${var.environment}"
  instance = local.cloudsql_instance_id
  password = random_password.db[0].result
}

resource "google_secret_manager_secret" "database_url" {
  count     = var.has_database ? 1 : 0
  secret_id = "${var.app_name}-${var.environment}-database-url"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "database_url" {
  count   = var.has_database ? 1 : 0
  secret  = google_secret_manager_secret.database_url[0].id
  secret_data = join("", [
    "postgresql://",
    google_sql_user.app[0].name,
    ":",
    random_password.db[0].result,
    "@/",
    google_sql_database.app[0].name,
    "?host=/cloudsql/",
    var.cloudsql_connection_name,
  ])

  depends_on = [google_sql_database.app, google_sql_user.app]
}

resource "google_secret_manager_secret_iam_member" "database_url_run_access" {
  count     = var.has_database ? 1 : 0
  secret_id = google_secret_manager_secret.database_url[0].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${data.google_project.project.number}-compute@developer.gserviceaccount.com"
}

