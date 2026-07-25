terraform {
  backend "s3" {
    bucket                = "id-terraform-state20260612164136440800000001"
    region                = "eu-west-3"
    workspace_key_prefix  = "secrets/bootstrap/openbao"
    key                   = "terraform.tfstate"
    encrypt               = true
    use_lockfile          = true
  }

  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 5.0"
    }
  }
}

# Address + token come from VAULT_ADDR / VAULT_TOKEN env vars (like the other
# roots read creds from their respective CLI config/env) — see README.
provider "vault" {}
