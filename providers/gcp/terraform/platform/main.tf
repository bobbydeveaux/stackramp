# ── State migrations ──────────────────────────────────────────────────────────
# These handle existing apps deployed before count was added to these resources.
# Safe to keep permanently — Terraform ignores moved blocks for new apps.

moved {
  from = google_firebase_hosting_site.app
  to   = google_firebase_hosting_site.app[0]
}

moved {
  from = random_string.site_suffix
  to   = random_string.site_suffix[0]
}

moved {
  from = google_cloud_run_v2_service_iam_member.public
  to   = google_cloud_run_v2_service_iam_member.public[0]
}

moved {
  from = google_cloud_run_v2_service.app
  to   = google_cloud_run_v2_service.app[0]
}

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
  count   = var.has_sso ? 0 : 1
  length  = 5
  special = false
  upper   = false
}

resource "google_firebase_hosting_site" "app" {
  count    = var.has_sso ? 0 : 1
  provider = google-beta
  project  = var.platform_project
  site_id  = "${var.app_name}-${random_string.site_suffix[0].result}-${var.environment}"

  lifecycle {
    ignore_changes = [site_id]
  }
}

# ── Custom Domain (Firebase Hosting, non-SSO only) ────────────────────────────

resource "google_firebase_hosting_custom_domain" "app" {
  count         = !var.has_sso && var.custom_domain != "" ? 1 : 0
  provider      = google-beta
  project       = var.platform_project
  site_id       = google_firebase_hosting_site.app[0].site_id
  custom_domain = var.custom_domain
}

# ── Cloud DNS records (if a managed zone is provided) ─────────────────────────
# Firebase populates required_dns_updates with TXT (ownership verification) and
# A records. Since Cloud DNS is authoritative, Terraform injects them directly —
# Firebase polls Cloud DNS, finds the TXT, auto-verifies, and starts serving.
# Records are only created once Firebase has returned non-empty rrdatas, so the
# first apply (TXT only) and subsequent applies (TXT + A) are both safe.

locals {
  # Firebase DNS (non-SSO only)
  dns_enabled          = !var.has_sso && var.custom_domain != "" && var.dns_zone_name != ""
  cloudsql_instance_id = var.has_database && var.cloudsql_connection_name != "" ? split(":", var.cloudsql_connection_name)[2] : ""
  is_subdomain         = local.dns_enabled && length(split(".", var.custom_domain)) > 2
  firebase_a_records   = ["199.36.158.100", "199.36.158.101"]

  # SSO DNS (points to LB static IP)
  sso_dns_enabled = var.has_sso && var.custom_domain != "" && var.dns_zone_name != ""

  # IAP member — domain:example.com or allAuthenticatedUsers
  iap_member = (var.iap_allowed_domain == "" || var.iap_allowed_domain == "*") ? "allAuthenticatedUsers" : "domain:${var.iap_allowed_domain}"
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
  rrdatas      = ["${google_firebase_hosting_site.app[0].site_id}.web.app."]
}

# ── Cloud Run Service ─────────────────────────────────────────────────────────
# Creates the service shell — actual deployment is done by the workflow

resource "google_cloud_run_v2_service" "app" {
  count               = var.has_backend ? 1 : 0
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

# Allow unauthenticated access (non-SSO apps only)
resource "google_cloud_run_v2_service_iam_member" "public" {
  count    = var.has_backend && !var.has_sso ? 1 : 0
  project  = var.platform_project
  location = var.region
  name     = google_cloud_run_v2_service.app[0].name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# ── SSO: IAP + HTTPS Load Balancer ───────────────────────────────────────────
# When sso: true — frontend served from Cloud Run (not Firebase Hosting),
# both services sit behind a single LB with IAP. The IAP OAuth client was
# created once at bootstrap and its credentials are stored in Secret Manager.

# Frontend Cloud Run service (serves nginx + built static files)
resource "google_cloud_run_v2_service" "frontend_sso" {
  count               = var.has_sso ? 1 : 0
  name                = "${var.app_name}-fe-${var.environment}"
  location            = var.region
  project             = var.platform_project
  deletion_protection = false

  template {
    containers {
      image = "nginxinc/nginx-unprivileged:alpine"
      ports {
        container_port = 8080
      }
    }
    # Only accept traffic from the HTTPS Load Balancer — IAP enforces authn there
    scaling {
      min_instance_count = 0
    }
  }

  ingress = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"

  lifecycle {
    ignore_changes = [
      template[0].containers[0].image,
    ]
  }
}

# Allow unauthenticated invocations — security is enforced by LB ingress restriction + IAP
resource "google_cloud_run_v2_service_iam_member" "iap_frontend_invoker" {
  count    = var.has_sso ? 1 : 0
  project  = var.platform_project
  location = var.region
  name     = google_cloud_run_v2_service.frontend_sso[0].name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# IAP SA invoker on backend — IAP requires run.invoker even when Cloud Run allows allUsers
resource "google_cloud_run_v2_service_iam_member" "iap_backend_invoker" {
  count    = var.has_sso && var.has_backend ? 1 : 0
  project  = var.platform_project
  location = var.region
  name     = google_cloud_run_v2_service.app[0].name
  role     = "roles/run.invoker"
  member   = "serviceAccount:service-${data.google_project.project.number}@gcp-sa-iap.iam.gserviceaccount.com"
}

resource "google_cloud_run_v2_service_iam_member" "iap_frontend_invoker_sa" {
  count    = var.has_sso ? 1 : 0
  project  = var.platform_project
  location = var.region
  name     = google_cloud_run_v2_service.frontend_sso[0].name
  role     = "roles/run.invoker"
  member   = "serviceAccount:service-${data.google_project.project.number}@gcp-sa-iap.iam.gserviceaccount.com"
}

# Read IAP credentials from Secret Manager (created at bootstrap)
data "google_secret_manager_secret_version" "iap_client_id" {
  count   = var.has_sso ? 1 : 0
  secret  = "stackramp-iap-client-id"
  project = var.platform_project
}

data "google_secret_manager_secret_version" "iap_client_secret" {
  count   = var.has_sso ? 1 : 0
  secret  = "stackramp-iap-client-secret"
  project = var.platform_project
}

# Static IP for the LB
resource "google_compute_global_address" "app" {
  count   = var.has_sso ? 1 : 0
  name    = "${var.app_name}-${var.environment}-ip"
  project = var.platform_project
}

# Managed SSL cert (provisioned automatically once DNS A record resolves)
resource "google_compute_managed_ssl_certificate" "app" {
  count   = var.has_sso && var.custom_domain != "" ? 1 : 0
  name    = "${var.app_name}-${var.environment}-cert"
  project = var.platform_project

  managed {
    domains = [var.custom_domain]
  }
}

# Serverless NEGs
resource "google_compute_region_network_endpoint_group" "frontend_neg" {
  count                 = var.has_sso ? 1 : 0
  name                  = "${var.app_name}-fe-${var.environment}-neg"
  network_endpoint_type = "SERVERLESS"
  region                = var.region
  project               = var.platform_project

  cloud_run {
    service = google_cloud_run_v2_service.frontend_sso[0].name
  }
}

resource "google_compute_region_network_endpoint_group" "backend_neg" {
  count                 = var.has_sso && var.has_backend ? 1 : 0
  name                  = "${var.app_name}-be-${var.environment}-neg"
  network_endpoint_type = "SERVERLESS"
  region                = var.region
  project               = var.platform_project

  cloud_run {
    service = google_cloud_run_v2_service.app[0].name
  }
}

# Backend services with IAP enabled
resource "google_compute_backend_service" "frontend_bs" {
  count                 = var.has_sso ? 1 : 0
  name                  = "${var.app_name}-fe-${var.environment}-bs"
  project               = var.platform_project
  protocol              = "HTTPS"
  load_balancing_scheme = "EXTERNAL_MANAGED"

  backend {
    group = google_compute_region_network_endpoint_group.frontend_neg[0].id
  }

  iap {
    enabled              = true
    oauth2_client_id     = data.google_secret_manager_secret_version.iap_client_id[0].secret_data
    oauth2_client_secret = data.google_secret_manager_secret_version.iap_client_secret[0].secret_data
  }
}

resource "google_compute_backend_service" "backend_bs" {
  count                 = var.has_sso && var.has_backend ? 1 : 0
  name                  = "${var.app_name}-be-${var.environment}-bs"
  project               = var.platform_project
  protocol              = "HTTPS"
  load_balancing_scheme = "EXTERNAL_MANAGED"

  backend {
    group = google_compute_region_network_endpoint_group.backend_neg[0].id
  }

  iap {
    enabled              = true
    oauth2_client_id     = data.google_secret_manager_secret_version.iap_client_id[0].secret_data
    oauth2_client_secret = data.google_secret_manager_secret_version.iap_client_secret[0].secret_data
  }
}

# URL map: /api/* → backend, everything else → frontend
resource "google_compute_url_map" "app" {
  count           = var.has_sso ? 1 : 0
  name            = "${var.app_name}-${var.environment}-urlmap"
  project         = var.platform_project
  default_service = google_compute_backend_service.frontend_bs[0].id

  host_rule {
    hosts        = var.custom_domain != "" ? [var.custom_domain] : ["*"]
    path_matcher = "paths"
  }

  path_matcher {
    name            = "paths"
    default_service = google_compute_backend_service.frontend_bs[0].id

    dynamic "path_rule" {
      for_each = var.has_backend ? [1] : []
      content {
        paths   = ["/api", "/api/*"]
        service = google_compute_backend_service.backend_bs[0].id
      }
    }
  }
}

# HTTP → HTTPS redirect
resource "google_compute_url_map" "redirect" {
  count   = var.has_sso ? 1 : 0
  name    = "${var.app_name}-${var.environment}-redirect"
  project = var.platform_project

  default_url_redirect {
    https_redirect = true
    strip_query    = false
  }
}

resource "google_compute_target_http_proxy" "redirect" {
  count   = var.has_sso ? 1 : 0
  name    = "${var.app_name}-${var.environment}-http-proxy"
  project = var.platform_project
  url_map = google_compute_url_map.redirect[0].id
}

resource "google_compute_global_forwarding_rule" "http_redirect" {
  count                 = var.has_sso ? 1 : 0
  name                  = "${var.app_name}-${var.environment}-http"
  project               = var.platform_project
  ip_address            = google_compute_global_address.app[0].address
  port_range            = "80"
  target                = google_compute_target_http_proxy.redirect[0].id
  load_balancing_scheme = "EXTERNAL_MANAGED"
}

# HTTPS proxy + forwarding rule
resource "google_compute_target_https_proxy" "app" {
  count            = var.has_sso && var.custom_domain != "" ? 1 : 0
  name             = "${var.app_name}-${var.environment}-https-proxy"
  project          = var.platform_project
  url_map          = google_compute_url_map.app[0].id
  ssl_certificates = [google_compute_managed_ssl_certificate.app[0].id]
}

resource "google_compute_global_forwarding_rule" "https" {
  count                 = var.has_sso && var.custom_domain != "" ? 1 : 0
  name                  = "${var.app_name}-${var.environment}-https"
  project               = var.platform_project
  ip_address            = google_compute_global_address.app[0].address
  port_range            = "443"
  target                = google_compute_target_https_proxy.app[0].id
  load_balancing_scheme = "EXTERNAL_MANAGED"
}

# DNS A record pointing to LB IP (SSO replaces Firebase DNS records)
resource "google_dns_record_set" "sso_a" {
  count        = local.sso_dns_enabled ? 1 : 0
  name         = "${var.custom_domain}."
  type         = "A"
  ttl          = 300
  managed_zone = var.dns_zone_name
  project      = var.platform_project
  rrdatas      = [google_compute_global_address.app[0].address]
}

# IAP access grants — who is allowed through the proxy
resource "google_iap_web_backend_service_iam_member" "frontend_access" {
  count               = var.has_sso ? 1 : 0
  project             = var.platform_project
  web_backend_service = google_compute_backend_service.frontend_bs[0].name
  role                = "roles/iap.httpsResourceAccessor"
  member              = local.iap_member
}

resource "google_iap_web_backend_service_iam_member" "backend_access" {
  count               = var.has_sso && var.has_backend ? 1 : 0
  project             = var.platform_project
  web_backend_service = google_compute_backend_service.backend_bs[0].name
  role                = "roles/iap.httpsResourceAccessor"
  member              = local.iap_member
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

