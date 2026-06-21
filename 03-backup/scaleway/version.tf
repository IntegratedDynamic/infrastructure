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

provider "infisical" {
  auth = {
    # Uncomment `universal` and comment `oidc` when running terraform locally.
    # universal = {}
    oidc = {}
  }
}
