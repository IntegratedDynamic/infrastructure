terraform {
  # Migrated to the dedicated Scaleway state bucket (00-foundation/scaleway,
  # state_buckets["iam_bootstrap_aws"]) — independent of the real AWS
  # credentials `provider "aws"` below uses to manage actual AWS resources.
  #
  # workspace_key_prefix already matched this root's own path; the workspace
  # name (env/01-iam-bootstrap-aws-dev.tfvars) is what the 2026-08-24
  # workspace-naming refacto fixed — suffixed -dev to reflect the actual
  # (dev, not prod) environment. Old state object left in place, orphaned on
  # purpose (never deleted).
  backend "s3" {
    bucket                      = "id-terraform-state-01-iam-bootstrap-aws"
    region                      = "fr-par"
    workspace_key_prefix        = "01-iam/bootstrap/aws"
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
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

# Credentials are resolved by the AWS SDK chain — NOT hardcoded here:
#   - local: `aws sso login` -> the provider defaults to your SSO admin session
#   - CI:    GitHub OIDC -> aws-actions/configure-aws-credentials sets env vars
provider "aws" {
  region = var.region
}
