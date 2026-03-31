output "launchpad_provider" {
  description = "Set as GitHub Variable: LAUNCHPAD_PROVIDER"
  value       = "gcp"
}

output "launchpad_project" {
  description = "Set as GitHub Variable: LAUNCHPAD_PROJECT"
  value       = var.platform_project
}

output "launchpad_region" {
  description = "Set as GitHub Variable: LAUNCHPAD_REGION"
  value       = var.region
}

output "launchpad_wif_provider" {
  description = "Set as GitHub Variable: LAUNCHPAD_WIF_PROVIDER"
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "launchpad_sa_email" {
  description = "Set as GitHub Variable: LAUNCHPAD_SA_EMAIL"
  value       = google_service_account.platform_cicd.email
}

output "artifact_registry_url" {
  description = "Docker registry URL for images"
  value       = "${google_artifact_registry_repository.launchpad_images.location}-docker.pkg.dev/${var.platform_project}/${google_artifact_registry_repository.launchpad_images.repository_id}"
}

output "github_variables_summary" {
  description = "Copy these values to your GitHub org/repo Variables"
  value = <<-EOT

    ┌──────────────────────────────────────────────────────────────────────┐
    │ Set these as GitHub Variables (Settings → Secrets and variables     │
    │ → Actions → Variables) at the org or repo level:                   │
    ├──────────────────────────────────────────────────────────────────────┤
    │                                                                    │
    │ LAUNCHPAD_PROVIDER     = gcp                                       │
    │ LAUNCHPAD_PROJECT      = ${var.platform_project}
    │ LAUNCHPAD_REGION       = ${var.region}
    │ LAUNCHPAD_WIF_PROVIDER = ${google_iam_workload_identity_pool_provider.github.name}
    │ LAUNCHPAD_SA_EMAIL     = ${google_service_account.platform_cicd.email}
    │                                                                    │
    └──────────────────────────────────────────────────────────────────────┘

  EOT
}
