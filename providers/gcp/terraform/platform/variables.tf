variable "app_name" {
  description = "Application name (slug)"
  type        = string
}

variable "environment" {
  description = "Environment (dev, prod)"
  type        = string
}

variable "platform_project" {
  description = "GCP project ID for the platform"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "europe-west1"
}

variable "custom_domain" {
  description = "Custom domain for this app (e.g. stackramp.io or guardian.stackramp.io). Empty = no custom domain."
  type        = string
  default     = ""
}

variable "dns_zone_name" {
  description = "Cloud DNS managed zone name (e.g. stackramp-io). Empty = DNS records not managed by Terraform (external domain — add records at your registrar). Auto-detected by the platform workflow from the app's domain."
  type        = string
  default     = ""
}

variable "domain_is_apex" {
  description = "Whether custom_domain is the apex of its Cloud DNS zone (→ A records) rather than a subdomain (→ CNAME). Computed by the platform workflow from the zone's dns_name, so multi-part TLDs (e.g. co.uk) are handled correctly."
  type        = bool
  default     = false
}

variable "backend_domain" {
  description = "Custom domain for the backend API (e.g. api.stackramp.io). Computed automatically from custom_domain. Empty = no custom domain."
  type        = string
  default     = ""
}

variable "has_backend" {
  description = "Whether the app has a backend service. When false, Cloud Run is not provisioned."
  type        = bool
  default     = false
}

variable "has_storage" {
  description = "Back-compat: whether to provision the legacy single GCS data bucket (storage: gcs). Superseded by buckets_json for the storage.buckets block form."
  type        = bool
  default     = false
}

variable "buckets_json" {
  description = <<-EOT
    JSON-encoded array of bucket configs from the storage.buckets block in
    stackramp.yaml. Each entry: { name, access, signed_urls, lifecycle_days }.
    Default "[]" = no block-form buckets. Independent of has_storage, which
    drives the legacy storage: gcs single-bucket path for back-compat.
    Example: [{"name":"downloads","access":"private","signed_urls":true,"lifecycle_days":0}]
  EOT
  type        = string
  default     = "[]"
}

variable "has_database" {
  description = "Whether to provision a Postgres database for this app within the shared Cloud SQL instance"
  type        = bool
  default     = false
}

variable "cloudsql_connection_name" {
  description = "Cloud SQL instance connection name (project:region:instance) from bootstrap. Required when has_database = true."
  type        = string
  default     = ""
}

variable "has_sso" {
  description = "Whether to enable IAP SSO for this app. Frontend is served from Cloud Run (not Firebase Hosting) with IAP enabled directly on the Cloud Run services."
  type        = bool
  default     = false
}

variable "frontend_sa_email" {
  description = "Custom SA for SSO frontend Cloud Run services. When set, frontend runs as this SA instead of default compute SA."
  type        = string
  default     = ""
}

variable "iap_allowed_domain" {
  description = "Google Workspace domain for IAP access (e.g. yourcompany.com). Use * for allAuthenticatedUsers. Sourced from STACKRAMP_IAP_DOMAIN."
  type        = string
  default     = ""
}

variable "has_mcp" {
  description = "Whether to provision a Cloud Run service for the MCP server. Always deployed with no-allow-unauthenticated and a domain: invoker (never allUsers)."
  type        = bool
  default     = false
}
