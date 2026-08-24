terraform {
  # Migrated to the dedicated Scaleway state bucket (00-foundation/scaleway,
  # state_buckets["secrets_openbao_managed"]).
  #
  # Prefix + workspace name now mirror this root's own path (2026-08-24
  # workspace-naming refacto, which also moved this domain from 05-secrets
  # to 11-secrets — postdating 10-cluster) — used to be
  # "secrets/managed/openbao" / "05-secrets-openbao-secrets" (segment order
  # didn't even match the directory path). No terraform.workspace naming
  # coupling in this root, so this is a plain state relocation, zero
  # resource impact. Old state object left in place under the old
  # prefix/workspace, orphaned on purpose (never deleted).
  backend "s3" {
    bucket                      = "id-terraform-state-05-secrets-openbao-managed"
    region                      = "fr-par"
    workspace_key_prefix        = "11-secrets/openbao/managed"
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
# 11-secrets/openbao/bootstrap's own state instead of a hand-copied variable.
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

# Authenticates as the `terraform` AppRole from 11-secrets/openbao/bootstrap —
# this root is the machine identity that role exists for. Address hardcoded,
# not read from VAULT_ADDR: OpenBao's own CLI populates BAO_ADDR/BAO_TOKEN,
# not Vault's VAULT_ADDR/VAULT_TOKEN, so relying on the env var is a trap (see
# the bootstrap root's version.tf/README for the incident this came from).
provider "vault" {
  # Defaults to the same internal Service address Argo Workflows already
  # uses in-cluster (http://openbao.openbao.svc:8200, matches
  # services/platform/openbao/init's baoAddr) — since infrastructure#81,
  # reachable here too through the WireGuard tunnel's internal-cluster DNS +
  # proxy-dynamic sidecar (04-vpn/wireguard-site-to-site/README.md's
  # "Internal cluster DNS" section) instead of the public route. Bring the tunnel up
  # first (`wg-quick up <peer_conf_paths output>`).
  #
  # Overridden via -var for the two other real execution contexts this root
  # runs in: the Argo Workflows CronWorkflow (gitops repo
  # services/platform/argo-workflows) passes this same address directly
  # (-var vault_address=http://openbao.openbao.svc:8200/ — redundant with
  # the default now, kept explicit in that chart's values since it's the
  # whole reason that CronWorkflow exists: OpenBao not being reachable from
  # outside the cluster for a while after boot, so it can't depend on this
  # default ever changing back). A direct port-forward (`kubectl
  # port-forward -n openbao openbao-0 8200:8200`, requires Kubernetes
  # permissions) is the third, for when the tunnel itself is the thing
  # being debugged: -var vault_address=http://127.0.0.1:8200/. The public
  # route (https://openbao.scalepack.fr/) still works too — that's still
  # there for human OIDC/UI login — just isn't the default anymore.
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
