terraform {
  # Remote state lives in the very bucket this root manages (chicken-and-egg:
  # see README.md for the one-time local-state bootstrap).
  #
  # Prefix + workspace name now mirror this root's own path (2026-08-24
  # workspace-naming refacto) — used to be "state-backend" /
  # "00-remote-state-backend". Old state object left in place, orphaned on
  # purpose (never deleted).
  backend "s3" {
    bucket = "id-terraform-state20260612164136440800000001"
    region = "eu-west-3"
    workspace_key_prefix = "00-foundation/aws"
    key                  = "terraform.tfstate"
    encrypt              = true
    use_lockfile         = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    # Pulled in transitively by module.iam_oidc_provider (fetches GitHub's
    # OIDC thumbprint dynamically instead of a hardcoded value).
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

# Credentials are resolved by the AWS SDK chain — NOT hardcoded here:
#   - local: `aws sso login` -> The provider will default on your sso session
#   - CI:    GitHub OIDC -> aws-actions/configure-aws-credentials sets env vars, which will default there too.

# Any environment with ~/.aws or AWS_* env vars properly configured will work
provider "aws" {
  region = var.region
}
