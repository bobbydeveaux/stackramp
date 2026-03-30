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
