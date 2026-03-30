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
