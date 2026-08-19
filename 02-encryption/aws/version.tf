terraform {
  # Migrated to the dedicated Scaleway state bucket (00-foundation/scaleway,
  # state_buckets["encryption_aws"]) — independent of the real AWS
  # credentials `provider "aws"` below uses to manage actual AWS resources.
  backend "s3" {
    bucket = "id-terraform-state-02-encryption-aws"
    region = "fr-par"
    # New backend key for this domain — moved out of 03-storage/scaleway
    # (formerly 03-backup/scaleway) via a real cross-backend `terraform state
    # mv`, not a directory rename.
    workspace_key_prefix        = "openbao-unseal/aws"
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

# Credentials are resolved by the AWS SDK chain, NOT hardcoded:
#   - local: `aws sso login` -> the provider defaults to your SSO admin session
#   - CI:    the openbao-unseal-ci role (01-iam/bootstrap/aws), assumed via
#            GitHub OIDC, scoped to exactly the KMS/IAM actions this root
#            needs
#
# Meant to run through CI once a workflow exists for it (same as
# 03-storage/scaleway, which also has no workflow yet) — not an
# admin/local-only concern anymore. It used to be: before openbao-unseal-ci
# existed, the only CI role available (terraform-state-access) was
# S3-state-only and couldn't touch KMS/IAM at all.
provider "aws" {
  region = var.aws_region
}
