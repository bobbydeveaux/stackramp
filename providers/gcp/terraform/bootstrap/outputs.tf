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
  value       = "${google_artifact_registry_repository.stackramp_images.location}-docker.pkg.dev/${var.platform_project}/${google_artifact_registry_repository.stackramp_images.repository_id}"
}

output "dns_zone_nameservers" {
  description = "Nameservers to set at your domain registrar (only when base_domain is set)"
  value       = local.dns_zone_nameservers
}

output "custom_domain_nameservers" {
  description = "Per custom domain, the GCP nameservers to set at that domain's registrar (delegate the whole domain to Cloud DNS)."
  value       = { for d, z in google_dns_managed_zone.custom : d => z.name_servers }
}

output "cloudsql_connection_name" {
  description = "Set as GitHub Variable: STACKRAMP_CLOUDSQL_CONNECTION (only when enable_postgres = true)"
  value       = var.enable_postgres ? google_sql_database_instance.platform[0].connection_name : ""
}

output "cloudsql_instance_name" {
  description = "Short instance name (without project/region prefix)"
  value       = var.enable_postgres ? google_sql_database_instance.platform[0].name : ""
}

output "vpc_connector_name" {
  description = "Set as GitHub Variable: STACKRAMP_VPC_CONNECTOR (only when postgres_private_ip = true)"
  value       = var.enable_postgres && var.postgres_private_ip ? google_vpc_access_connector.platform[0].name : ""
}

output "frontend_sa_email" {
  description = "Frontend runtime SA email (only when postgres_private_ip = true)"
  value       = var.postgres_private_ip ? google_service_account.frontend_runtime[0].email : ""
}

output "iap_enabled" {
  description = "Whether IAP was configured (iap_allowed_domain was set)"
  value       = var.iap_allowed_domain != ""
}

output "machine_consumer_emails" {
  description = "SA emails for machine consumers. Use these in apps' `mcp.allowed_service_accounts` (stackramp.yaml). Mint each key manually: gcloud iam service-accounts keys create <name>.json --iam-account=<email>"
  value       = { for name, sa in google_service_account.machine_consumer : name => sa.email }
}

output "github_variables_summary" {
  description = "Copy these values to your GitHub org/repo Variables"
  value       = <<-EOT

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
    ${var.enable_postgres ? "│ STACKRAMP_CLOUDSQL_CONNECTION = ${google_sql_database_instance.platform[0].connection_name}${var.postgres_private_ip ? "\n    │ STACKRAMP_VPC_CONNECTOR       = ${google_vpc_access_connector.platform[0].name}" : ""}" : ""}
    ${var.iap_allowed_domain != "" ? "│ STACKRAMP_IAP_DOMAIN          = ${var.iap_allowed_domain}" : ""}
    │                                                                    │
    └──────────────────────────────────────────────────────────────────────┘

  EOT
}
