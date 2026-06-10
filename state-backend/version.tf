terraform {
  # Remote state in the bucket this root itself manages. Creds: see mise.toml.
  backend "s3" {
    bucket = "id-terraform-state"
    key    = "state-backend/terraform.tfstate"
    region = "fr-par"

    # Root-specific prefix so this root's workspaces don't mix with others'.
    workspace_key_prefix = "state-backend"

    endpoints = { s3 = "https://s3.fr-par.scw.cloud" }

    # Disable the backend's AWS-only preflight checks (IMDS, STS account-id,
    # region allowlist): Scaleway speaks the S3 API but isn't AWS itself.
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
  }

  required_providers {
    scaleway = {
      source  = "scaleway/scaleway"
      version = "~> 2.0"
    }
  }
}

# Creds, region and project_id come from the scw CLI config (like cluster/scaleway/).
provider "scaleway" {}
