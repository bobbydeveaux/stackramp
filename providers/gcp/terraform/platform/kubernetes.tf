# Per-app provisioning for `kubernetes:` apps (A3). The chart + _kubernetes.yml
# deploy the app onto the shared GKE cluster; this file provisions the GCP-side
# resources a k8s app needs so the deploy is fully self-service (no manual GCP):
#   - binds the app's Cloud SQL proxy KSA to the shared cloudsql-client GSA
#     (Workload Identity, keyless),
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
  # Namespace the app is Helm-installed into, env-suffixed so dev and prod
  # co-exist on the SAME shared cluster (environments segregate by namespace,
  # not by cluster — mirrors how the one Cloud SQL instance holds <db>-dev and
  # <db>-prod, and how Cloud Run runs both envs in one project). The deploy job
  # consumes this via the k8s_namespace output so helm -n and this WI binding
  # never drift apart.
  k8s_namespace = "${var.kubernetes_namespace}-${var.environment}"
  # Shared Cloud SQL client GSA — created ONCE at bootstrap (gke.tf) with
  # roles/cloudsql.client. Every k8s app's proxy WI-binds to it. Deterministic
  # name so this per-app terraform needn't cross into bootstrap state. Using a
  # shared identity keeps the deploy SA at SA-level IAM only (the WI binding
  # below) — it never needs project-IAM-admin to grant cloudsql.client per app.
  gke_cloudsql_sa_email = "gke-cloudsql-client@${var.platform_project}.iam.gserviceaccount.com"
}

# Bind this app's proxy KSA (<namespace>/cloudsql-proxy) to the shared
# cloudsql-client GSA via Workload Identity. google_service_account_iam_member
# is additive + only needs SA-level IAM (iam.serviceAccountAdmin), which the
# platform CICD SA has — no project-IAM-admin required.
resource "google_service_account_iam_member" "k8s_cloudsql_wi" {
  count              = var.has_kubernetes ? 1 : 0
  service_account_id = "projects/${var.platform_project}/serviceAccounts/${local.gke_cloudsql_sa_email}"
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.platform_project}.svc.id.goog[${local.k8s_namespace}/${local.k8s_cloudsql_ksa}]"
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

# DNS A-record: the app's host -> the shared Gateway's global IP. var.custom_domain
# arrives already env-derived (dev => <app>.dev.<base>, prod => <app>.<base>; empty
# for a truly-custom domain in dev), so this points exactly at what the chart's
# HTTPRoute claims. The Gateway's wildcard cert already covers the host — no
# per-app cert. Gated so ingress-free apps (no domain) create no record.
resource "google_dns_record_set" "k8s_gateway_a" {
  count        = var.has_kubernetes && var.custom_domain != "" && var.gke_gateway_ip != "" ? 1 : 0
  name         = "${var.custom_domain}."
  type         = "A"
  ttl          = 300
  managed_zone = var.dns_zone_name
  project      = var.platform_project
  rrdatas      = [var.gke_gateway_ip]
}
