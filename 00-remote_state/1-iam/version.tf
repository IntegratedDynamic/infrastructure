terraform {
  # Remote state on the shared org S3 bucket, under this root's own key prefix.
  # In CI the GitHub OIDC role (identity/00-ci-trust/) provides the credentials; it is
  # granted R/W on this bucket, so `init`/`plan`/`apply` work without static keys.
  backend "s3" {
    bucket = "id-terraform-state20260612164136440800000001"
    region = "eu-west-3"
    # Prefix kept as "s3-lister-role" (≠ this root's path state/10-access/) on
    # purpose: the state key is decoupled from the directory, so the repo
    # restructure was a pure move with zero state migration.
    workspace_key_prefix = "s3-lister-role"
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

provider "aws" {
  region = var.region
}
