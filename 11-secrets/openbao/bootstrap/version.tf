terraform {
  # Same state bucket this root always used (00-foundation/scaleway,
  # state_buckets["secrets_openbao_bootstrap"]) — left in place, unused,
  # when this root was deleted 2026-09-30 (infra#115 follow-up, part 2,
  # AppRole removal) rather than torn down (this repo's own convention:
  # never delete an orphaned state object on the same pass that retires
  # the root). Reused here for the SAME root's return under a different
  # design (part 3: a minimal Kubernetes-auth trust anchor instead of
  # AppRole) rather than standing up a new bucket for what is, in spirit,
  # the same "human-applied trust anchor" domain.
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
# session doesn't populate the env var this hashicorp/vault provider
# expects. No auth_login block, ever: this root only exists to create the
# trust anchor OTHER identities log in with (see main.tf) — it has no
# identity of its own to log in as, so it always authenticates as
# var.root_token, the one genuinely unavoidable use of a raw root/admin
# token in this whole platform (every other root's own README explains why
# IT doesn't need one; this is the root that exists so they don't have to).
provider "vault" {
  address = var.vault_address
  token   = var.root_token
}

variable "vault_address" {
  description = "OpenBao's address. Defaults to the in-cluster Service (only reachable via a WireGuard tunnel or kubectl port-forward from outside the cluster — see managed/README.md's own vault_address variable for the same tradeoff, this root just has no -var-file convention of its own since it's applied by hand, rarely)."
  type        = string
  default     = "http://openbao.openbao.svc:8200/"
}

variable "root_token" {
  description = "OpenBao root/admin token — the ONLY credential this root ever authenticates with (see provider \"vault\" block's own comment for why). Pass via TF_VAR_root_token, never a CLI flag, to keep it out of shell history."
  type        = string
  sensitive   = true
}
