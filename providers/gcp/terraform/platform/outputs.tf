output "site_id" {
  description = "Firebase Hosting site ID (empty when sso=true)"
  value       = var.has_sso ? "" : google_firebase_hosting_site.app[0].site_id
}

output "frontend_url" {
  description = "Frontend URL"
  value = var.has_sso ? (
    var.custom_domain != "" ? "https://${var.custom_domain}" : "https://${google_cloud_run_v2_service.frontend_sso[0].uri}"
  ) : (
    var.custom_domain != "" ? "https://${var.custom_domain}" : "https://${google_firebase_hosting_site.app[0].site_id}.web.app"
  )
}

output "backend_url" {
  description = "Primary backend Cloud Run URI (backwards compatible)"
  value = local.is_multi_backend ? (
    google_cloud_run_v2_service.backends[local.primary_backend_key].uri
  ) : (
    length(google_cloud_run_v2_service.app) > 0 ? google_cloud_run_v2_service.app[0].uri : ""
  )
}

output "backend_urls" {
  description = "Map of all backend service URLs keyed by service name. Empty for single-backend apps."
  value = local.is_multi_backend ? {
    for name, svc in google_cloud_run_v2_service.backends : name => svc.uri
  } : {}
}

output "lb_ip" {
  description = "Load balancer static IP (only when sso=true)"
  value       = var.has_sso ? google_compute_global_address.app[0].address : ""
}

output "storage_bucket" {
  description = "GCS bucket name for app data (empty if not enabled)"
  value       = var.has_storage ? google_storage_bucket.app_data[0].name : ""
}

output "database_secret_name" {
  description = "Secret Manager secret ID for DATABASE_URL (empty if database not enabled)"
  value       = var.has_database ? google_secret_manager_secret.database_url[0].secret_id : ""
}

output "cloudsql_connection_name" {
  description = "Cloud SQL connection name passed through for use in Cloud Run deployment"
  value       = var.has_database ? var.cloudsql_connection_name : ""
}
