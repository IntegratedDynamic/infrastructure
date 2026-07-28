terraform {
  backend "s3" {
    bucket                = "id-terraform-state20260612164136440800000001"
    region                = "eu-west-3"
    workspace_key_prefix  = "secrets/managed/openbao"
    key                   = "terraform.tfstate"
    encrypt               = true
    use_lockfile          = true
  }

  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# Authenticates as the `terraform` AppRole from 05-secrets/openbao/bootstrap —
# this root is the machine identity that role exists for. Address hardcoded,
# not read from VAULT_ADDR: OpenBao's own CLI populates BAO_ADDR/BAO_TOKEN,
# not Vault's VAULT_ADDR/VAULT_TOKEN, so relying on the env var is a trap (see
# the bootstrap root's version.tf/README for the incident this came from).
provider "vault" {
  address = "https://openbao.scalepack.fr/"
  # address = "http://127.0.0.1:8200/"

  auth_login {
    path = "auth/approle/login"
    parameters = {
      role_id   = var.approle_role_id
      secret_id = var.approle_secret_id
    }
  }
}
