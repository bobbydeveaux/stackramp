variable "platform_project" {
  description = "GCP project ID for the shared platform (e.g. bj-platform-dev)"
  type        = string
}

variable "github_owner" {
  description = "GitHub org or username that owns repos deploying to this platform"
  type        = string
  default     = "bobbydeveaux"
}

variable "github_owners" {
  description = "GitHub orgs/usernames whose repos may deploy to this platform via WIF. When empty, falls back to [github_owner]. Set this to trust more than one owner."
  type        = list(string)
  default     = []
}

variable "custom_domains" {
  description = "Additional apex domains to host in Cloud DNS, one managed zone each (e.g. [\"flowbydeveaux.co.uk\"]). Apps can then set `domain:` to these (or a subdomain of them) and the platform auto-detects the zone and injects records. Delegate each domain's nameservers to GCP at your registrar (see the custom_domain_nameservers output)."
  type        = list(string)
  default     = []
}

variable "environment" {
  description = "Environment name (dev or prod)"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "Environment must be 'dev' or 'prod'."
  }
}

variable "region" {
  description = "GCP region for all resources"
  type        = string
  default     = "europe-west1"
}

variable "billing_account" {
  description = "GCP billing account ID (optional)"
  type        = string
  default     = ""
}

variable "base_domain" {
  description = "Base domain for the platform (e.g. stackramp.io). Leave empty to skip DNS zone creation."
  type        = string
  default     = ""
}

variable "create_dns_zone" {
  description = "Create a new Cloud DNS zone for base_domain. Set to false if the zone already exists in the project (e.g. created by domain registration)."
  type        = bool
  default     = true
}

variable "platform_secrets" {
  description = "Secret names to create in Secret Manager as platform-injectable. Values are set manually in the GCP Console after apply — never committed here."
  type        = list(string)
  default     = []
}

variable "enable_postgres" {
  description = "Provision a shared Cloud SQL Postgres instance for the platform. Apps opt-in via `database: postgres` in stackramp.yaml."
  type        = bool
  default     = false
}

variable "postgres_private_ip" {
  description = "Use private IP for Cloud SQL (requires VPC connector at ~£52/month). When false, Cloud SQL uses public IP with Cloud SQL Auth Proxy — no VPC needed."
  type        = bool
  default     = false
}

variable "postgres_tier" {
  description = "Cloud SQL machine tier for the shared Postgres instance."
  type        = string
  default     = "db-f1-micro"
}

variable "iap_allowed_domain" {
  description = "Google Workspace domain whose members are granted IAP access (e.g. yourcompany.com). Use * for any Google account. Leave empty to skip IAP setup."
  type        = string
  default     = ""
}

variable "machine_consumers" {
  description = "Machine consumer systems (e.g. [\"agentops\"]) that call apps' MCP services with a service-account identity. Each entry becomes an SA with NO project roles — it exists purely as a verifiable identity. Apps grant access per-app via `mcp.allowed_service_accounts` in stackramp.yaml."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.machine_consumers : can(regex("^[a-z]([a-z0-9-]{4,28})[a-z0-9]$", c))])
    error_message = "Each machine consumer must be a valid SA account_id: 6-30 chars, lowercase letters/digits/hyphens, starting with a letter."
  }
}

variable "machine_consumer_keys" {
  description = "Also create a JSON key per machine consumer and store it in Secret Manager (machine-consumer-<name>-key). CAVEAT: the private key is persisted in Terraform state — acceptable for a single-operator platform with a locked-down state bucket; set false and mint keys manually with gcloud if that's not you. Fetch: gcloud secrets versions access latest --secret=machine-consumer-<name>-key"
  type        = bool
  default     = false
}

