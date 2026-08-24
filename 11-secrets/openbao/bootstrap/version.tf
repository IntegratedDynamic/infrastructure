terraform {
  # Migrated to the dedicated Scaleway state bucket (00-foundation/scaleway,
  # state_buckets["secrets_openbao_bootstrap"]).
  #
  # Prefix + workspace name now mirror this root's own path (2026-08-24
  # workspace-naming refacto, which also moved this domain from 05-secrets
  # to 11-secrets — postdating 10-cluster) — used to be
  # "secrets/bootstrap/openbao" / "05-secrets-openbao" (segment order didn't
  # even match the directory path). No terraform.workspace naming coupling
  # in this root, so this is a plain state relocation, zero resource impact.
  # Old state object left in place under the old prefix/workspace, orphaned
  # on purpose (never deleted).
  backend "s3" {
    bucket                      = "id-terraform-state-05-secrets-openbao-bootstrap"
    region                      = "fr-par"
    workspace_key_prefix        = "11-secrets/openbao/bootstrap"
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
