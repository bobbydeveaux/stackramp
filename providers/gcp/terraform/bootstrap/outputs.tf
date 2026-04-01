output "stackramp_provider" {
  description = "Set as GitHub Variable: STACKRAMP_PROVIDER"
  value       = "gcp"
}

output "stackramp_project" {
  description = "Set as GitHub Variable: STACKRAMP_PROJECT"
  value       = var.platform_project
}

output "stackramp_region" {
  description = "Set as GitHub Variable: STACKRAMP_REGION"
  value       = var.region
}

output "stackramp_wif_provider" {
  description = "Set as GitHub Variable: STACKRAMP_WIF_PROVIDER"
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "stackramp_sa_email" {
  description = "Set as GitHub Variable: STACKRAMP_SA_EMAIL"
  value       = google_service_account.platform_cicd.email
}

output "artifact_registry_url" {
  description = "Docker registry URL for images"
  value       = "${google_artifact_registry_repository.launchpad_images.location}-docker.pkg.dev/${var.platform_project}/${google_artifact_registry_repository.launchpad_images.repository_id}"
}

output "dns_zone_nameservers" {
  description = "Nameservers to set at your domain registrar (only when base_domain is set)"
  value       = var.base_domain != "" ? google_dns_managed_zone.platform[0].name_servers : []
}

output "github_variables_summary" {
  description = "Copy these values to your GitHub org/repo Variables"
  value = <<-EOT

    ┌──────────────────────────────────────────────────────────────────────┐
    │ Set these as GitHub Variables (Settings → Secrets and variables     │
    │ → Actions → Variables) at the org or repo level:                   │
    ├──────────────────────────────────────────────────────────────────────┤
    │                                                                    │
    │ STACKRAMP_PROVIDER     = gcp                                       │
    │ STACKRAMP_PROJECT      = ${var.platform_project}
    │ STACKRAMP_REGION       = ${var.region}
    │ STACKRAMP_WIF_PROVIDER = ${google_iam_workload_identity_pool_provider.github.name}
    │ STACKRAMP_SA_EMAIL     = ${google_service_account.platform_cicd.email}
    ${var.base_domain != "" ? "│ STACKRAMP_BASE_DOMAIN  = ${var.base_domain}\n    │ STACKRAMP_DNS_ZONE     = ${replace(var.base_domain, ".", "-")}" : ""}
    │                                                                    │
    └──────────────────────────────────────────────────────────────────────┘

  EOT
}
