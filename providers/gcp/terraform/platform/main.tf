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

# SSO and non-SSO subdomain CNAMEs were merged into a single resource (frontend_cname)
# to make SSO transitions an in-place update instead of a destroy/create race.
moved {
  from = google_dns_record_set.sso_cname[0]
  to   = google_dns_record_set.frontend_cname[0]
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
# For an apex custom domain, Firebase needs two records in the authoritative
# zone, both of which we can derive deterministically (no dependency on the
# resource's computed required_dns_updates, which can't be for_each'd at plan):
#   1. A  → Firebase Hosting's serving IP (199.36.158.100).
#   2. TXT "hosting-site=<site_id>" → proves this site owns the domain, so
#      Firebase auto-verifies and mints the SSL cert via the HTTP-01 challenge.
# Subdomains verify via their CNAME instead, so they don't need the TXT.

locals {
  dns_enabled          = var.custom_domain != "" && var.dns_zone_name != ""
  cloudsql_instance_id = var.has_database && var.cloudsql_connection_name != "" ? split(":", var.cloudsql_connection_name)[2] : ""
  # Apex (e.g. flowbydeveaux.co.uk) → A records; subdomain → CNAME. domain_is_apex
  # is computed from the zone's dns_name upstream, so multi-part TLDs are correct.
  is_subdomain = local.dns_enabled && !var.domain_is_apex
  # Firebase Hosting's single apex serving IP. (Publishing the extra .101 makes
  # Firebase's ACME challenge fail on it and blocks cert minting.)
  firebase_a_records = ["199.36.158.100"]

  # Subdomain CNAME target — Cloud Run domain mapping for SSO apps, Firebase site for Firebase apps
  cname_target = var.has_sso ? "ghs.googlehosted.com." : (length(google_firebase_hosting_site.app) > 0 ? "${google_firebase_hosting_site.app[0].site_id}.web.app." : "")

  # IAP members — one IAM binding per allowed Google Workspace domain.
  # STACKRAMP_IAP_DOMAIN may be a single domain ("bobbyjason.co.uk"), a
  # comma-separated list ("thedeveauxgroup.co.uk,bobbyjason.co.uk"), or "" / "*"
  # for allAuthenticatedUsers. Multiple domains → multiple `domain:` members, so
  # IAP admits users from ANY listed domain (IAP IAM is additive). Backward-
  # compatible: a single domain yields exactly the previous single binding.
  iap_domains = (var.iap_allowed_domain == "" || var.iap_allowed_domain == "*") ? [] : [
    for d in split(",", var.iap_allowed_domain) : trimspace(d) if trimspace(d) != ""
  ]
  # Each entry becomes an IAP IAM member. Entries may be:
  #   - an explicit member ("user:a@b", "group:g@b", "serviceAccount:x", "domain:b") → used as-is
  #   - an email ("a@b")  → user:a@b   (needed when the user's Workspace domain is
  #                          NOT the GCP org's domain — domain: bindings only
  #                          expand for the resource org's own Cloud Identity)
  #   - a bare domain ("b") → domain:b
  iap_members = length(local.iap_domains) == 0 ? ["allAuthenticatedUsers"] : [
    for e in local.iap_domains :
    can(regex("^(user|group|serviceAccount|domain):", e)) ? e : (
      can(regex("@", e)) ? "user:${e}" : "domain:${e}"
    )
  ]
}

# Apex domain: A records pointing at Firebase's stable load-balancer IPs (non-SSO only).
# SSO apps use Cloud Run Domain Mapping which doesn't support apex domains.
resource "google_dns_record_set" "frontend_a" {
  count        = local.dns_enabled && !local.is_subdomain && !var.has_sso ? 1 : 0
  name         = "${var.custom_domain}."
  type         = "A"
  ttl          = 300
  managed_zone = var.dns_zone_name
  project      = var.platform_project
  rrdatas      = local.firebase_a_records
}

# Apex ownership verification: "hosting-site=<site_id>" proves this Firebase
# site owns the domain, so Firebase auto-verifies and mints the SSL cert with
# no manual TXT step. site_id is known at plan time, so this is deterministic.
# Subdomains verify via their CNAME, so they don't need this.
resource "google_dns_record_set" "frontend_verify" {
  count        = local.dns_enabled && !local.is_subdomain && !var.has_sso ? 1 : 0
  name         = "${var.custom_domain}."
  type         = "TXT"
  ttl          = 300
  managed_zone = var.dns_zone_name
  project      = var.platform_project
  rrdatas      = ["\"hosting-site=${google_firebase_hosting_site.app[0].site_id}\""]
}

# Subdomain CNAME — single resource so transitioning between Firebase and SSO Cloud Run
# is an in-place update (changed rrdatas), avoiding a destroy/create DNS race condition.
resource "google_dns_record_set" "frontend_cname" {
  count        = local.is_subdomain ? 1 : 0
  name         = "${var.custom_domain}."
  type         = "CNAME"
  ttl          = 300
  managed_zone = var.dns_zone_name
  project      = var.platform_project
  rrdatas      = [local.cname_target]
}

# ── Cloud Run Service ─────────────────────────────────────────────────────────
# Creates the service shell — actual deployment is done by the workflow

resource "google_cloud_run_v2_service" "app" {
  count               = var.has_backend ? 1 : 0
  name                = "${var.app_name}-${var.environment}"
  location            = var.region
  project             = var.platform_project
  deletion_protection = false
  iap_enabled         = false

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
      client,
      client_version,
      template,
    ]
  }
}

# Allow access (non-SSO apps only). Org policy blocks allUsers, so if an
# iap_allowed_domain is set we restrict to that domain instead of going fully public.
resource "google_cloud_run_v2_service_iam_member" "public" {
  count    = var.has_backend && !var.has_sso ? 1 : 0
  project  = var.platform_project
  location = var.region
  name     = google_cloud_run_v2_service.app[0].name
  role     = "roles/run.invoker"
  member   = var.iap_allowed_domain != "" ? "domain:${var.iap_allowed_domain}" : "allUsers"
}

# Grant default compute SA invoker on backend — used by the Go proxy
# to call the backend with an identity token (service-to-service auth)
resource "google_cloud_run_v2_service_iam_member" "frontend_to_backend_invoker" {
  count    = var.has_sso && var.has_backend ? 1 : 0
  project  = var.platform_project
  location = var.region
  name     = google_cloud_run_v2_service.app[0].name
  role     = "roles/run.invoker"
  member   = var.frontend_sa_email != "" ? "serviceAccount:${var.frontend_sa_email}" : "serviceAccount:${data.google_project.project.number}-compute@developer.gserviceaccount.com"
}

# ── SSO: IAP directly on Cloud Run (no load balancer) ────────────────────────
# When sso: true — frontend served from Cloud Run (not Firebase Hosting),
# IAP is enabled directly on each Cloud Run service. No LB required.

# Frontend Cloud Run service (serves nginx + built static files)
resource "google_cloud_run_v2_service" "frontend_sso" {
  count               = var.has_sso ? 1 : 0
  name                = "${var.app_name}-fe-${var.environment}"
  location            = var.region
  project             = var.platform_project
  deletion_protection = false
  iap_enabled         = true

  template {
    service_account = var.frontend_sa_email != "" ? var.frontend_sa_email : null
    containers {
      image = "nginxinc/nginx-unprivileged:alpine"
      ports {
        container_port = 8080
      }
    }
    scaling {
      min_instance_count = 0
    }
  }

  lifecycle {
    ignore_changes = [
      client,
      client_version,
      template,
    ]
  }
}

# IAP SA invoker — IAP service agent needs run.invoker to forward authed requests
resource "google_cloud_run_v2_service_iam_member" "iap_frontend_invoker_sa" {
  count    = var.has_sso ? 1 : 0
  project  = var.platform_project
  location = var.region
  name     = google_cloud_run_v2_service.frontend_sso[0].name
  role     = "roles/run.invoker"
  member   = "serviceAccount:service-${data.google_project.project.number}@gcp-sa-iap.iam.gserviceaccount.com"
}

# IAP access grants — who is allowed through IAP
resource "google_iap_web_cloud_run_service_iam_member" "frontend_access" {
  for_each               = var.has_sso ? toset(local.iap_members) : toset([])
  project                = data.google_project.project.number
  location               = var.region
  cloud_run_service_name = google_cloud_run_v2_service.frontend_sso[0].name
  role                   = "roles/iap.httpsResourceAccessor"
  member                 = each.value
}

# ── Custom domain mapping for SSO apps ────────────────────────────────────────
# Cloud Run handles SSL automatically via the domain mapping.
# DNS must have a CNAME pointing to ghs.googlehosted.com.

resource "google_cloud_run_domain_mapping" "sso_frontend" {
  count    = var.has_sso && var.custom_domain != "" ? 1 : 0
  name     = var.custom_domain
  location = var.region
  project  = var.platform_project

  metadata {
    namespace = var.platform_project
  }

  spec {
    route_name = google_cloud_run_v2_service.frontend_sso[0].name
  }
}

# ── GCS Buckets ───────────────────────────────────────────────────────────────
# Two paths, both back-compatible:
#
#   1. Legacy single bucket — storage: gcs in stackramp.yaml sets has_storage.
#      Keeps the original resource name (app_data) and bucket name
#      ({app_name}-data-{env}) so existing apps see no destroy/recreate.
#
#   2. storage.buckets block — buckets_json carries an array of bucket configs.
#      Provisioned with for_each keyed on logical name. Bucket name follows
#      {project}-{app}-{env}-{name}. All buckets are private (public access
#      prevention enforced) — public buckets are out of scope. Each bucket
#      grants the Cloud Run runtime SA objectAdmin scoped to that bucket,
#      optional age-based lifecycle delete, and (when signed_urls) keyless V4
#      signing via serviceAccountTokenCreator.
#
# The Cloud Run runtime SA for backends is the project default compute SA. The
# frontend_sa_email var is the SSO frontend proxy identity, NOT the backend
# runtime identity, so it is deliberately not used here.

data "google_project" "project" {
  project_id = var.platform_project
}

locals {
  runtime_sa_email = "${data.google_project.project.number}-compute@developer.gserviceaccount.com"
  runtime_sa_id    = "projects/${var.platform_project}/serviceAccounts/${local.runtime_sa_email}"

  # Decode the storage.buckets block into a map keyed by logical name, applying
  # defaults for omitted fields. signed_urls and lifecycle_days default off.
  # Buckets are always private — public access is out of scope and is rejected
  # earlier in platform-action/action.yml, so no access field is carried here.
  bucket_list = jsondecode(var.buckets_json)
  buckets = {
    for b in local.bucket_list : b.name => {
      name           = b.name
      signed_urls    = try(b.signed_urls, false)
      lifecycle_days = try(b.lifecycle_days, 0)
      bucket_name    = "${var.platform_project}-${var.app_name}-${var.environment}-${b.name}"
    }
  }

  # Logical name -> resolved bucket name, for the env-var output the workflow
  # turns into BUCKET_<NAME_UPPER> injections.
  bucket_env = {
    for k, v in local.buckets : k => v.bucket_name
  }

  # Any block-form bucket asking for keyless V4 signed URLs needs the runtime SA
  # granted token-creator on itself. One grant covers all such buckets.
  any_signed_urls = length([for k, v in local.buckets : k if v.signed_urls]) > 0
}

# ── Legacy single bucket (storage: gcs) ───────────────────────────────────────

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

# Grant Cloud Run runtime SA (default compute SA) objectAdmin on the legacy bucket
resource "google_storage_bucket_iam_member" "app_data_run" {
  count  = var.has_storage ? 1 : 0
  bucket = google_storage_bucket.app_data[0].name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${local.runtime_sa_email}"
}

# ── storage.buckets block ─────────────────────────────────────────────────────

resource "google_storage_bucket" "app_bucket" {
  for_each      = local.buckets
  name          = each.value.bucket_name
  project       = var.platform_project
  location      = var.region
  force_destroy = false

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  dynamic "lifecycle_rule" {
    for_each = each.value.lifecycle_days > 0 ? [each.value.lifecycle_days] : []
    content {
      action {
        type = "Delete"
      }
      condition {
        age = lifecycle_rule.value
      }
    }
  }

  lifecycle {
    prevent_destroy = false

    # GCS bucket names are capped at 63 characters. The resolved name is
    # {project}-{app}-{env}-{logical}, so a long project prefix can overflow
    # and fail at apply with an opaque GCS 400. Fail early with a clear message
    # naming the logical bucket, the resolved name, and its length.
    precondition {
      condition     = length(each.value.bucket_name) <= 63
      error_message = "GCS bucket name for logical bucket '${each.value.name}' is ${length(each.value.bucket_name)} characters (max 63): '${each.value.bucket_name}'. Shorten the bucket 'name', app name, or environment."
    }
  }
}

# Grant the Cloud Run runtime SA objectAdmin scoped to each block-form bucket
resource "google_storage_bucket_iam_member" "app_bucket_run" {
  for_each = local.buckets
  bucket   = google_storage_bucket.app_bucket[each.key].name
  role     = "roles/storage.objectAdmin"
  member   = "serviceAccount:${local.runtime_sa_email}"
}

# Keyless V4 signed URLs: grant the runtime SA token-creator on ITSELF so the
# backend can call signBlob with no exported key file. Granted once when any
# block-form bucket sets signed_urls: true.
resource "google_service_account_iam_member" "runtime_sa_token_creator" {
  count              = local.any_signed_urls ? 1 : 0
  service_account_id = local.runtime_sa_id
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${local.runtime_sa_email}"
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
  count  = var.has_database ? 1 : 0
  secret = google_secret_manager_secret.database_url[0].id
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

