terraform {
  # Migrated to the dedicated Scaleway state bucket (00-foundation/scaleway,
  # state_buckets["iam_bootstrap_scaleway"]).
  backend "s3" {
    bucket = "id-terraform-state-01-iam-bootstrap-scaleway"
    region = "fr-par"
    # Prefix + workspace name now mirror this root's own path (2026-08-24
    # workspace-naming refacto) — used to be "github-ci" from before this
    # root existed under its current directory. Old state object left in
    # place under the old prefix/workspace, orphaned on purpose (never
    # deleted).
    workspace_key_prefix        = "01-iam/bootstrap/scaleway"
    key                         = "terraform.tfstate"
    encrypt                     = true
    use_lockfile                = true
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
    use_path_style              = true
    endpoints = {
      s3 = "https://s3.fr-par.scw.cloud"
    }
  }

  required_providers {
    scaleway = {
      source  = "scaleway/scaleway"
      version = "~> 2.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}

# Creds, region and project_id come from the scw CLI config (like the other roots).
provider "scaleway" {}
