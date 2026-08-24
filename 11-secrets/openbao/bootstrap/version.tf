terraform {
  # Migrated to the dedicated Scaleway state bucket (00-foundation/scaleway,
  # state_buckets["secrets_openbao_bootstrap"]).
  backend "s3" {
    bucket                      = "id-terraform-state-05-secrets-openbao-bootstrap"
    region                      = "fr-par"
    workspace_key_prefix        = "secrets/bootstrap/openbao"
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
    vault = {
      source  = "hashicorp/vault"
      version = "~> 5.0"
    }
  }
}

# Address hardcoded (not read from VAULT_ADDR): OpenBao's own CLI uses
# BAO_ADDR/BAO_TOKEN, not Vault's VAULT_ADDR/VAULT_TOKEN — a `bao login`
# session doesn't populate the env var this hashicorp/vault provider expects.
# Only the token stays in the environment — see README.
provider "vault" {
  # Same hostname as the public route, resolved through the WireGuard
  # tunnel via split-DNS while it's up — see
  # 05-secrets/openbao/managed/version.tf's comment for the full rationale.
  address = "https://openbao.scalepack.fr/"
  # address = "http://127.0.0.1:8200/"  # kubectl port-forward, independent of the tunnel
  # token = var.root_token
}
