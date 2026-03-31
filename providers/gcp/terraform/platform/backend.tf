terraform {
  backend "gcs" {
    # Bucket and prefix are passed via -backend-config at init time:
    #   terraform init \
    #     -backend-config="bucket=${PLATFORM_PROJECT}-tf-state" \
    #     -backend-config="prefix=${APP_NAME}-${ENVIRONMENT}/"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 7.0"
    }
  }
}
