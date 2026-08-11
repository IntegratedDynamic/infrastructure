terraform {
  backend "s3" {
    bucket               = "id-terraform-state20260612164136440800000001"
    region               = "eu-west-3"
    workspace_key_prefix = "secrets/bootstrap/openbao"
    key                  = "terraform.tfstate"
    encrypt              = true
    use_lockfile         = true
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
