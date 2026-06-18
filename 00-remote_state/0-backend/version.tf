terraform {
  # Remote state lives in the very bucket this root manages (chicken-and-egg:
  # see README.md for the one-time local-state bootstrap).
  backend "s3" {
    bucket = "id-terraform-state20260612164136440800000001"
    region = "eu-west-3"
    # Prefix kept as "state-backend" (≠ this root's path state/00-backend/) on
    # purpose: the state key is decoupled from the directory, so the repo
    # restructure was a pure move with zero state migration.
    workspace_key_prefix = "state-backend"
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
#   - local: `aws sso login` -> The provider will default on your sso session
#   - CI:    GitHub OIDC -> aws-actions/configure-aws-credentials sets env vars, which will default there too.

# Any environment with ~/.aws or AWS_* env vars properly configured will work
provider "aws" {
  region = var.region
}
