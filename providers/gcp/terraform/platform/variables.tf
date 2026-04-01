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
