terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket               = "terraform-states20260401151521472800000001"
    key                  = "state-bucket/terraform.tfstate"
    region               = "eu-west-3"
    profile              = "Sandbox"
    workspace_key_prefix = "workspaces"
  }
}

provider "aws" {
  region = var.aws_region
  profile = var.aws_profile
}
