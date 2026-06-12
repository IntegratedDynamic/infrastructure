terraform {
  backend "s3" {
    bucket = "id-terraform-state20260612164136440800000001"
    region = "eu-west-3"
    workspace_key_prefix = "github-ci"
    key    = "terraform.tfstate"
    encrypt = true
    use_lockfile = true
  }

  

  required_providers {
    scaleway = {
      source  = "scaleway/scaleway"
      version = "~> 2.0"
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

# Creds, region and project_id come from the scw CLI config (like the other roots).
provider "scaleway" {}

provider "infisical" {
  auth = {
    universal = {
      client_id     = var.infisical_client_id
      client_secret = var.infisical_client_secret
    }
  }
}
