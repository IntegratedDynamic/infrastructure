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

# Three ways this root's own applier can authenticate to OpenBao — which one
# is live is picked by var.vault_auth_method, never more than one at once
# (each dynamic block below is empty, i.e. entirely absent from the
# rendered config, unless it's the selected method).
#
# infra#115 follow-up (2026-09-30): "approle" used to be the only option.
# Confirmed live against a restored ephemeral-cluster OpenBao snapshot that
# the AppRole `secret_id` (11-secrets/openbao/bootstrap, generated once
# 2026-07-25, "rotate by tainting" never actually run since) had been purged
# by OpenBao itself (`bao list auth/approle/role/terraform/secret-id` came
# back empty — role_id and the `terraform` policy were both still intact and
# correct, only the secret_id was gone), breaking Crossplane's
# provider-opentofu Workspace (this root's in-cluster, unattended applier)
# with a 403 on the login call itself. AppRole's whole shape requires
# SOMETHING to mint and hand out that secret_id out-of-band, with no
# automatic renewal — exactly the kind of static, easy-to-forget credential
# Kubernetes auth doesn't have at all: the Workspace pod's own projected
# ServiceAccount token is auto-rotated by Kubernetes itself, nothing for
# this repo to remember to rotate. AppRole stays the default (and stays
# needed) because it's the only one of the three that works from OUTSIDE a
# trusted cluster at all (an admin's laptop, CI) — Kubernetes auth only
# works from a pod OpenBao's kubernetes auth backend config already trusts.
variable "vault_auth_method" {
  description = "Which of the three auth_login mechanisms below this root's own applier uses. \"approle\" (default): the AppRole identity from 11-secrets/openbao/bootstrap — portable, the only one that works from an admin's laptop or CI with no cluster context, but a static secret_id someone has to remember to rotate (see vault_kubernetes_auth_backend_role.crossplane's own comment in main.tf for the incident this follows up on). \"kubernetes\": for the in-cluster provider-opentofu Workspace — no long-lived secret at all, the pod's own auto-rotated ServiceAccount token is presented instead. \"token\": a root/admin token (var.root_token) for a one-off bootstrap apply (e.g. creating the \"crossplane\" Kubernetes-auth role itself, before it exists, or rotating a dead AppRole secret_id) or debugging via kubectl port-forward."
  type        = string
  default     = "approle"
  validation {
    condition     = contains(["approle", "kubernetes", "token"], var.vault_auth_method)
    error_message = "vault_auth_method must be \"approle\", \"kubernetes\", or \"token\"."
  }
}

# Only read when var.vault_auth_method = "kubernetes" — the role_name
# vault_kubernetes_auth_backend_role.crossplane (main.tf) creates, bound to
# provider-opentofu's own ServiceAccount (gitops repo
# services/platform/crossplane/chart's DeploymentRuntimeConfig pins that
# name deterministically, not revision-hashed, specifically so a binding
# like this one stays valid across provider upgrades).
variable "vault_kubernetes_role" {
  description = "Kubernetes auth role name (auth/kubernetes/role/<name>) this root's applier logs in as when vault_auth_method = \"kubernetes\"."
  type        = string
  default     = "crossplane"
}

# Authenticates as one of three identities depending on var.vault_auth_method
# — see that variable's own comment. Address hardcoded, not read from
# VAULT_ADDR: OpenBao's own CLI populates BAO_ADDR/BAO_TOKEN, not Vault's
# VAULT_ADDR/VAULT_TOKEN, so relying on the env var is a trap (see the
# bootstrap root's version.tf/README for the incident this came from).
provider "vault" {
  # Defaults to the same internal Service address Argo Workflows already
  # uses in-cluster (http://openbao.openbao.svc:8200, matches
  # services/platform/openbao/init's baoAddr) — since infrastructure#81,
  # reachable here too through the WireGuard tunnel's internal-cluster DNS +
  # proxy-dynamic sidecar (04-vpn/wireguard-site-to-site/README.md's
  # "Internal cluster DNS" section) instead of the public route. Bring the tunnel up
  # first (`wg-quick up <peer_conf_paths output>`).
  #
  # Overridden via -var for the other real execution contexts this root
  # runs in: the in-cluster Crossplane Workspace (gitops repo
  # services/platform/crossplane/config) passes this same address directly
  # (redundant with the default now, kept explicit since it's the whole
  # reason that Workspace exists: OpenBao not being reachable from outside
  # the cluster for a while after boot, so it can't depend on this default
  # ever changing back). A direct port-forward (`kubectl port-forward -n
  # openbao openbao-0 8200:8200`, requires Kubernetes permissions) is for
  # when the tunnel itself is the thing being debugged, or for a one-off
  # `-var vault_auth_method=token` bootstrap apply:
  # -var vault_address=http://127.0.0.1:8200/. The public route
  # (https://openbao.scalepack.fr/) still works too — that's still there for
  # human OIDC/UI login — just isn't the default anymore.
  address = var.vault_address

  dynamic "auth_login" {
    for_each = var.vault_auth_method == "approle" ? [1] : []
    content {
      path = "auth/approle/login"
      parameters = {
        role_id   = data.terraform_remote_state.openbao_bootstrap.outputs.role_id
        secret_id = data.terraform_remote_state.openbao_bootstrap.outputs.secret_id
      }
    }
  }

  # No dedicated auth_login_kubernetes block in hashicorp/vault ~> 5.0
  # (confirmed against this provider version's own schema, 5.10.1) — plain
  # auth_login against auth/kubernetes/login, same shape as the approle
  # block above. file() reads the pod's own projected ServiceAccount token
  # from the standard in-cluster path -- only ever evaluated when this
  # dynamic block's for_each actually produces the one element, i.e. only
  # inside the provider-opentofu pod where that file exists at all. See
  # vault_kubernetes_auth_backend_role.crossplane (main.tf) for the role
  # this logs into.
  dynamic "auth_login" {
    for_each = var.vault_auth_method == "kubernetes" ? [1] : []
    content {
      path = "auth/kubernetes/login"
      parameters = {
        role = var.vault_kubernetes_role
        jwt  = file("/var/run/secrets/kubernetes.io/serviceaccount/token")
      }
    }
  }

  token = var.vault_auth_method == "token" ? var.root_token : null
}

variable "root_token" {
  description = "OpenBao root/admin token — only read when vault_auth_method = \"token\" (a one-off bootstrap apply or kubectl-port-forward debugging session). Pass via TF_VAR_root_token, never a CLI flag, to keep it out of shell history."
  default     = null
  type        = string
  sensitive   = true
}
