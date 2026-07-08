# Per-app provisioning for `kubernetes:` apps (A3). The chart + _kubernetes.yml
# deploy the app onto the shared GKE cluster; this file provisions the GCP-side
# resources a k8s app needs so the deploy is fully self-service (no manual GCP):
#   - a Cloud SQL client identity the in-cluster proxy assumes via Workload
#     Identity (keyless),
#   - platform-generated secrets (jwt, bootstrap) written to Secret Manager for
#     ESO to sync — no human involvement.
# Terraform OWNS these names and exposes them as outputs; the deploy job passes
# them to Helm via --set, so nothing is hardcoded across the terraform/chart
# boundary. All gated on has_kubernetes (default false → inert for every other
# app). The DB itself is provisioned by the existing has_database path; its
# database_url secret is written in TCP form (via the in-cluster proxy) when
# has_kubernetes — see google_secret_manager_secret_version.database_url.

locals {
  # KSA (in the app namespace) the Cloud SQL proxy pod runs as; the chart's
  # proxy ServiceAccount is set to this via --set.
  k8s_cloudsql_ksa = "cloudsql-proxy"
  # Secret Manager name prefix for this app+env; the chart's ExternalSecret
  # references <prefix>-<key>.
  k8s_secret_prefix = "${var.app_name}-${var.environment}"
}

# Cloud SQL client identity for the in-cluster proxy (keyless — assumed via
# Workload Identity, no SA key).
resource "google_service_account" "k8s_cloudsql" {
  count        = var.has_kubernetes ? 1 : 0
  account_id   = "${var.app_name}-cloudsql"
  display_name = "${var.app_name} Cloud SQL proxy (GKE)"
  description  = "Assumed by the ${var.app_name} Cloud SQL Auth Proxy pod via Workload Identity."
}

resource "google_project_iam_member" "k8s_cloudsql_client" {
  count   = var.has_kubernetes ? 1 : 0
  project = var.platform_project
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.k8s_cloudsql[0].email}"
}

# Bind the proxy KSA (namespace/cloudsql-proxy) to the GSA.
resource "google_service_account_iam_member" "k8s_cloudsql_wi" {
  count              = var.has_kubernetes ? 1 : 0
  service_account_id = google_service_account.k8s_cloudsql[0].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.platform_project}.svc.id.goog[${var.kubernetes_namespace}/${local.k8s_cloudsql_ksa}]"
}

# Platform-generated app secrets → Secret Manager, for ESO to sync. No human
# involvement (unlike the app's external API keys, which are separate shells the
# operator populates once).
resource "random_password" "k8s_jwt" {
  count   = var.has_kubernetes ? 1 : 0
  length  = 48
  special = false
}

resource "random_password" "k8s_bootstrap" {
  count   = var.has_kubernetes ? 1 : 0
  length  = 48
  special = false
}

resource "google_secret_manager_secret" "k8s_generated" {
  for_each  = var.has_kubernetes ? toset(["jwt-secret", "bootstrap-token"]) : toset([])
  secret_id = "${local.k8s_secret_prefix}-${each.key}"
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "k8s_generated" {
  for_each = var.has_kubernetes ? {
    "jwt-secret"      = random_password.k8s_jwt[0].result
    "bootstrap-token" = random_password.k8s_bootstrap[0].result
  } : {}
  secret      = google_secret_manager_secret.k8s_generated[each.key].id
  secret_data = each.value
}
