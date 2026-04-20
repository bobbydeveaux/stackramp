# Copy this file to terraform.tfvars and fill in your values
platform_project = "tt-hackspace"
github_owner     = "toucanberry"
environment      = "dev"
region           = "europe-west1"
base_domain      = "tbhack.io"
create_dns_zone  = false

platform_secrets = [
  "LASTFM_API_KEY",
  "YOUTUBE_API_KEY",
]

enable_postgres = true
postgres_tier = "db-f1-micro"

iap_allowed_domain = "toucanberry.com"
