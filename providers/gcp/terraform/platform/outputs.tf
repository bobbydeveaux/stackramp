output "site_id" {
  description = "Firebase Hosting site ID (includes random suffix)"
  value       = google_firebase_hosting_site.app.site_id
}

output "frontend_url" {
  description = "Frontend URL — custom domain if configured, otherwise Firebase .web.app URL"
  value       = var.custom_domain != "" ? "https://${var.custom_domain}" : "https://${google_firebase_hosting_site.app.site_id}.web.app"
}

output "backend_url" {
  description = "Backend Cloud Run URI"
  value       = google_cloud_run_v2_service.app.uri
}

output "storage_bucket" {
  description = "GCS bucket name for app data (empty if not enabled)"
  value       = var.has_storage ? google_storage_bucket.app_data[0].name : ""
}
