terraform {
  # Remote state on the shared org S3 bucket (same bucket every other root uses),
  # under this root's own key so its state/blast-radius stay isolated.
  backend "s3" {
    bucket = "id-terraform-state20260612164136440800000001"
    region = "eu-west-3"
    # Prefix kept as "aws-github-oidc" (≠ this root's path identity/00-ci-trust/)
    # on purpose: the state key is decoupled from the directory, so the repo
    # restructure was a pure move with zero state migration.
    workspace_key_prefix = "aws-github-oidc"
    key                  = "terraform.tfstate"
    encrypt              = true
    use_lockfile         = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

# Credentials are resolved by the AWS SDK chain — NOT hardcoded here:
#   - local: `aws sso login` -> the provider defaults to your SSO session
#   - CI:    this very role, assumed via GitHub OIDC by
#            aws-actions/configure-aws-credentials, which sets AWS_* env vars
#
# No Scaleway / Infisical / time provider here: this root only manages AWS IAM.
provider "aws" {
  region = var.region
}
