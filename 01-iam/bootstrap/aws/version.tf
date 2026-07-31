terraform {
  backend "s3" {
    bucket               = "id-terraform-state20260612164136440800000001"
    region               = "eu-west-3"
    workspace_key_prefix = "01-iam/bootstrap/aws"
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
#   - local: `aws sso login` -> the provider defaults to your SSO admin session
#   - CI:    GitHub OIDC -> aws-actions/configure-aws-credentials sets env vars
provider "aws" {
  region = var.region
}
