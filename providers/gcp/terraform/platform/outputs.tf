output "site_id" {
  description = "Firebase Hosting site ID (empty when sso=true)"
  value       = var.has_sso ? "" : google_firebase_hosting_site.app[0].site_id
}

output "frontend_url" {
  description = "Frontend URL"
  value = var.has_sso ? (
    var.custom_domain != "" ? "https://${var.custom_domain}" : google_cloud_run_v2_service.frontend_sso[0].uri
    ) : (
    var.custom_domain != "" ? "https://${var.custom_domain}" : "https://${google_firebase_hosting_site.app[0].site_id}.web.app"
  )
}

output "backend_url" {
  description = "Backend Cloud Run URI"
  value       = var.has_backend ? google_cloud_run_v2_service.app[0].uri : ""
}

output "storage_bucket" {
  description = "Legacy single GCS bucket name for storage: gcs (empty if not enabled). Back-compat only."
  value       = var.has_storage ? google_storage_bucket.app_data[0].name : ""
}

output "bucket_env_json" {
  description = <<-EOT
    JSON object mapping logical bucket name -> resolved GCS bucket name for the
    storage.buckets block. The backend deploy job turns each entry into a
    BUCKET_<NAME_UPPER> env var. Empty object "{}" when no block-form buckets.
  EOT
  value       = jsonencode(local.bucket_env)
}

output "database_secret_name" {
  description = "Secret Manager secret ID for DATABASE_URL (empty if database not enabled)"
  value       = var.has_database ? google_secret_manager_secret.database_url[0].secret_id : ""
}

output "cloudsql_connection_name" {
  description = "Cloud SQL connection name passed through for use in Cloud Run deployment"
  value       = var.has_database ? var.cloudsql_connection_name : ""
}

output "mcp_url" {
  description = "MCP server Cloud Run URI (empty when mcp: not configured)"
  value       = var.has_mcp ? google_cloud_run_v2_service.mcp[0].uri : ""
}

# ── Kubernetes app provisioning (A3) — consumed by _kubernetes.yml → helm --set,
# so the chart never hardcodes these names.
output "k8s_cloudsql_sa_email" {
  description = "Cloud SQL client GSA the proxy pod assumes via Workload Identity (empty when no kubernetes: block)."
  value       = var.has_kubernetes ? google_service_account.k8s_cloudsql[0].email : ""
}

output "k8s_cloudsql_ksa" {
  description = "Namespace ServiceAccount name the proxy pod runs as (WI-bound to k8s_cloudsql_sa_email)."
  value       = var.has_kubernetes ? local.k8s_cloudsql_ksa : ""
}

output "k8s_secret_prefix" {
  description = "Secret Manager name prefix (<app>-<env>) the chart's ExternalSecret references as <prefix>-<key>."
  value       = var.has_kubernetes ? local.k8s_secret_prefix : ""
}
