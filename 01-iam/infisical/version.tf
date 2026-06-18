terraform {
  # Remote state on the shared org S3 bucket (same bucket every other root uses),
  # under this root's own key so its state/blast-radius stay isolated. Fresh
  # prefix for a brand-new root — no state to migrate.
  backend "s3" {
    bucket               = "id-terraform-state20260612164136440800000001"
    region               = "eu-west-3"
    workspace_key_prefix = "infisical-github-oidc"
    key                  = "terraform.tfstate"
    encrypt              = true
    use_lockfile         = true
  }

  required_providers {
    infisical = {
      source  = "infisical/infisical"
      version = "~> 0.16"
    }
  }
}

# The provider authenticates with a universal-auth machine identity (the
# bootstrap identity). Its client_id / client_secret come from *.auto.tfvars
# (per-developer, gitignored — see default.auto.tfvars). Host defaults to
# https://app.infisical.com.
provider "infisical" {}
