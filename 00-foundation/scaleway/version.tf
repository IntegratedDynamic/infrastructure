terraform {
  # Bootstrapped: created while this root's own state still lived in the AWS
  # bucket, then repointed here and migrated with `terraform init
  # -migrate-state` — the same one-time chicken-and-egg pattern
  # 00-foundation/aws used for itself. See README.md for the confirmed
  # backend config findings (path style, checksum, credential wiring).
  #
  # workspace_key_prefix mirrors this root's own path (00-foundation/scaleway)
  # and the workspace name (env/00-foundation-scaleway-dev.tfvars) mirrors it
  # too, suffixed -dev — part of the 2026-08-24 workspace-naming refacto that
  # made every root's backend key coherent with its directory path. The old
  # state-backend-scaleway/00-remote-state-backend/terraform.tfstate object is
  # left in place in the same bucket, orphaned on purpose (never deleted).
  backend "s3" {
    bucket                      = "id-terraform-state-00-foundation-scaleway"
    region                      = "fr-par"
    workspace_key_prefix        = "00-foundation/scaleway"
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

# Creds, region and project_id come from the scw CLI config (like the other
# Scaleway roots).
provider "scaleway" {}
