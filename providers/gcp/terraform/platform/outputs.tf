output "frontend_url" {
  description = "Firebase Hosting URL"
  value       = "https://${google_firebase_hosting_site.app.site_id}.web.app"
}

output "backend_url" {
  description = "Cloud Run service URL"
  value       = google_cloud_run_v2_service.app.uri
}
