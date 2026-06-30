terraform {
  backend "s3" {
    bucket               = "id-terraform-state20260612164136440800000001"
    region               = "eu-west-3"
    workspace_key_prefix = "backup/scaleway"
    key                  = "terraform.tfstate"
    encrypt              = true
    use_lockfile         = true
  }

  required_providers {
    scaleway = {
      source  = "scaleway/scaleway"
      version = "~> 2.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    infisical = {
      source  = "infisical/infisical"
      version = "~> 0.16"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}

provider "scaleway" {}

# AWS provider — used ONLY by kms.tf (OpenBao auto-unseal key + scoped IAM user).
# Credentials are resolved by the AWS SDK chain, NOT hardcoded:
#   - local: `aws sso login` -> the provider defaults to your SSO admin session
#
# IMPORTANT — apply path: these AWS resources (kms:CreateKey, iam:CreateUser,
# iam:CreateAccessKey) CANNOT be applied by the backup CI workflow, which assumes
# the S3-only `tf-state-access` role (and the CI permissions boundary explicitly
# denies IAM users / access keys). kms.tf is therefore an ADMIN-APPLIED, run-it-
# locally concern. A push that changes kms.tf will fail the backup CI apply.
provider "aws" {
  region = var.aws_region
}

# provider "infisical" {
#   auth = {
#     # Uncomment `universal` and comment `oidc` when running terraform locally.
#     # universal = {}
#     oidc = {}
#   }
# }
