variable "platform_project" {
  description = "GCP project ID for the shared platform (e.g. bj-platform-dev)"
  type        = string
}

variable "github_owner" {
  description = "GitHub org or username that owns repos deploying to this platform"
  type        = string
  default     = "bobbydeveaux"
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

variable "postgres_tier" {
  description = "Cloud SQL machine tier for the shared Postgres instance."
  type        = string
  default     = "db-f1-micro"
}
