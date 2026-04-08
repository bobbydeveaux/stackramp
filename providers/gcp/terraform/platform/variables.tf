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
  description = "Cloud DNS managed zone name (e.g. stackramp-io). Empty = DNS records not managed by Terraform."
  type        = string
  default     = ""
}

variable "backend_domain" {
  description = "Custom domain for the backend API (e.g. api.stackramp.io). Computed automatically from custom_domain. Empty = no custom domain."
  type        = string
  default     = ""
}

variable "has_storage" {
  description = "Whether to provision a GCS bucket for this app"
  type        = bool
  default     = false
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
