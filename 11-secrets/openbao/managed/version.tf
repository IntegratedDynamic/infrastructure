terraform {
  # Migrated to the dedicated Scaleway state bucket (00-foundation/scaleway,
  # state_buckets["secrets_openbao_managed"]).
  backend "s3" {
    bucket                      = "id-terraform-state-05-secrets-openbao-managed"
    region                      = "fr-par"
    workspace_key_prefix        = "secrets/managed/openbao"
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
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.0"
    }
  }
}

# role_id/secret_id for the `terraform` AppRole — read straight from
# 05-secrets/openbao/bootstrap's own state instead of a hand-copied variable.
# Safe to reference from the provider block below: this data source has no
# dependency on the vault provider itself (it's a plain S3 backend read), so
# there's no ordering cycle — same category of pattern as
# 10-cluster/scaleway/version.tf's kubernetes/helm providers reading straight
# off a resource attribute.
data "terraform_remote_state" "openbao_bootstrap" {
  backend = "s3"
  config = merge(local.scaleway_state_backend, {
    bucket = var.openbao_bootstrap_state_bucket
    key    = var.openbao_bootstrap_state_key
  })
}

# Authenticates as the `terraform` AppRole from 05-secrets/openbao/bootstrap —
# this root is the machine identity that role exists for. Address hardcoded,
# not read from VAULT_ADDR: OpenBao's own CLI populates BAO_ADDR/BAO_TOKEN,
# not Vault's VAULT_ADDR/VAULT_TOKEN, so relying on the env var is a trap (see
# the bootstrap root's version.tf/README for the incident this came from).
provider "vault" {
  # Defaults to OpenBao's public route — same hostname whether or not the
  # WireGuard tunnel is up, on purpose: split-DNS (the tunnel's dns
  # sidecar, gitops repo's services/platform/wireguard/config) resolves
  # this to the tunnel's own address (04-vpn/wireguard) while it's up,
  # routing privately through Envoy Gateway's real Service (proxy-gateway
  # sidecar) instead of the public internet. Same address either way —
  # bring the tunnel up first (`wg-quick up <peer_conf_paths output>`), or
  # this just hits the real public route (fine; that's still there for
  # human OIDC/UI login, this provider just doesn't need it anymore).
  #
  # Overridden via -var for the two other real execution contexts this root
  # runs in: the Argo Workflows CronWorkflow (gitops repo
  # services/platform/argo-workflows) passes the in-cluster Service address
  # (http://openbao.openbao.svc:8200, matches services/platform/openbao/
  # init's baoAddr) — the whole reason that CronWorkflow exists is OpenBao
  # not being reachable from outside the cluster for a while after boot, so
  # it never needs the tunnel/public-route dance below. A direct port-
  # forward (`kubectl port-forward -n openbao openbao-0 8200:8200`,
  # requires Kubernetes permissions) is the third: -var
  # vault_address=http://127.0.0.1:8200/.
  address = var.vault_address

  # address = "http://127.0.0.1:8200"
  # token = var.root_token

  auth_login {
    path = "auth/approle/login"
    parameters = {
      role_id   = data.terraform_remote_state.openbao_bootstrap.outputs.role_id
      secret_id = data.terraform_remote_state.openbao_bootstrap.outputs.secret_id
    }
  }
}

variable "root_token" {
  description = "Temporary variable used for debug with kubectl port-forward with openbao in hearly stage"
  default     = null
  type        = string
  sensitive   = true
}
