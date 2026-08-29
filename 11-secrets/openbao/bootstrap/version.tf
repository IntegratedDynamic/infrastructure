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
    # Pulled in by OpenTofu's s3 state backend (unlike Terraform's, its
    # backend depends on the AWS provider); not used directly by this root.
    # Constraint kept in step with the real-AWS roots (00-foundation/aws etc.).
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
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
  # Same internal Service address Argo Workflows already uses in-cluster
  # (gitops repo's services/platform/argo-workflows), reachable here through
  # the WireGuard tunnel's internal-cluster DNS + proxy-dynamic sidecar
  # (04-vpn/wireguard-site-to-site/README.md's "Internal cluster DNS" section,
  # infrastructure#81) — bring the tunnel up first (`wg-quick up
  # <peer_conf_paths output>`). No -var override exists for this root (it
  # only ever runs admin-applied locally, never in CI or in-cluster, unlike
  # 11-secrets/openbao/managed's var.vault_address), so this is hardcoded
  # the same way the previous public-route default was.
  address = "http://openbao.openbao.svc:8200/"
  # address = "http://127.0.0.1:8200/"  # kubectl port-forward, independent of the tunnel
  # token = var.root_token
}
