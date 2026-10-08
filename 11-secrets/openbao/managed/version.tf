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

# infra#115 follow-up (2026-09-30, part 2): AppRole is GONE — removed
# entirely, along with the 11-secrets/openbao/bootstrap root that used to
# mint it (see that root's own git-history-final commit message for the
# full teardown). Confirmed live against a restored ephemeral-cluster
# OpenBao snapshot that the AppRole `secret_id` (generated once 2026-07-25,
# "rotate by tainting" never actually run since) had been purged by OpenBao
# itself — role_id and the `terraform` policy were both still intact and
# correct, only the secret_id was gone — breaking Crossplane's
# provider-opentofu Workspace with a 403 on the login call itself.
#
# Investigating the fix (this root's own README, "Why AppRole and not
# OIDC") turned up that AppRole's original justification — "a
# service/pipeline authenticating without a human in the loop" — never
# actually applied to this root's OWN non-in-cluster execution context: an
# admin's laptop is a HUMAN, at an interactive session, for which this
# repo's OIDC-via-Dex was already the established pattern everywhere else
# (ArgoCD, Grafana, human OpenBao UI login) — this root's provider config
# was simply the one place still wired to a static machine credential for a
# case that never needed one. No CI workflow applies this root today either
# (confirmed: no real reference to it in .github/workflows/, only an
# unrelated comment) — the "portable, no cluster context" property that WAS
# AppRole's genuine advantage over Kubernetes auth has no current consumer.
#
# Two auth mechanisms remain, picked by var.vault_auth_method (never more
# than one at once — each dynamic block below is empty, i.e. entirely
# absent from the rendered config, unless it's the selected method), plus
# var.root_token as a separate, explicitly-emergency-only escape hatch (see
# that variable's own comment).
variable "vault_auth_method" {
  description = "Which auth_login mechanism below this root's own applier uses. \"oidc\" (default): a human admin's interactive browser login via Dex (auth_login_oidc, role = var.vault_oidc_role) — for an admin's laptop, the only non-in-cluster execution context this root has today. \"kubernetes\": for the in-cluster provider-opentofu Workspace — no long-lived secret at all, the pod's own auto-rotated ServiceAccount token is presented instead (vault_kubernetes_auth_backend_role.crossplane, 11-secrets/openbao/bootstrap/main.tf — a different root, see that variable's own comment below for why)."
  type        = string
  default     = "oidc"
  validation {
    condition     = contains(["oidc", "kubernetes"], var.vault_auth_method)
    error_message = "vault_auth_method must be \"oidc\" or \"kubernetes\" — \"approle\" was removed (infra#115 follow-up, 2026-09-30). For a one-off bootstrap/emergency apply, set var.root_token (TF_VAR_root_token) instead — it overrides whichever method is selected here, see provider \"vault\" block's own comment."
  }
}

# Only read when var.vault_auth_method = "oidc" — a role on the SAME `oidc`
# auth backend (auth_backend.oidc, main.tf) the human `admin` role already
# uses, deliberately its OWN, narrower role rather than reusing `admin`:
# `admin` grants full sys/* sudo (meant for a human doing anything via the
# UI), while this root's own applies only ever need the same "terraform"
# policy AppRole used to grant (vault_policy.terraform — now
# 11-secrets/openbao/bootstrap/main.tf, see var.vault_kubernetes_role's own
# comment below for why) — reusing `admin` here would silently widen every
# routine `tofu apply`'s blast radius from "structure + kv/apps" to
# "everything, with sudo".
variable "vault_oidc_role" {
  description = "OIDC auth role name (auth/oidc/role/<name>, see vault_jwt_auth_backend_role.terraform_cli in main.tf) this root's applier logs in as when vault_auth_method = \"oidc\"."
  type        = string
  default     = "terraform-cli"
}

# Only read when var.vault_auth_method = "kubernetes" — the role_name
# vault_kubernetes_auth_backend_role.crossplane creates, bound to
# provider-opentofu's own ServiceAccount (gitops repo
# services/platform/crossplane/chart's DeploymentRuntimeConfig pins that
# name deterministically, not revision-hashed, specifically so a binding
# like this one stays valid across provider upgrades). Lives in
# 11-secrets/openbao/bootstrap/main.tf, NOT this root, and deliberately so
# (infra#115 follow-up, 2026-09-30, part 3): Crossplane's provider-opentofu
# Workspace is this root's OWN unattended applier — if its trust anchor
# lived here too, it would need to already be applied to authenticate in
# order to apply it, the exact chicken-and-egg AppRole used to solve before
# part 2 removed it. bootstrap/ breaks that loop the same way, applied once
# by a human (var.root_token) instead.
variable "vault_kubernetes_role" {
  description = "Kubernetes auth role name (auth/kubernetes/role/<name>) this root's applier logs in as when vault_auth_method = \"kubernetes\"."
  type        = string
  default     = "crossplane"
}

# Authenticates via var.vault_auth_method's chosen mechanism, UNLESS
# var.root_token is set (non-null) — that's a separate, explicit emergency
# override, not a third method: when present it takes priority regardless
# of vault_auth_method, for a one-off bootstrap apply (e.g. this root's own
# very first apply against a fresh OpenBao, before
# vault_jwt_auth_backend_role.terraform_cli exists for var.vault_auth_method
# = "oidc" to log into) or kubectl-port-forward debugging. Address
# hardcoded, not read from VAULT_ADDR: OpenBao's own CLI
# populates BAO_ADDR/BAO_TOKEN, not Vault's VAULT_ADDR/VAULT_TOKEN, so
# relying on the env var is a trap (confirmed live, see git history for the
# incident this came from).
provider "vault" {
  # Defaults to the same internal Service address Argo Workflows already
  # uses in-cluster (http://openbao.openbao.svc:8200, matches
  # services/platform/openbao/init's baoAddr) — since infrastructure#81,
  # reachable here too through the WireGuard tunnel's internal-cluster DNS +
  # proxy-dynamic sidecar (04-vpn/wireguard-site-to-site/README.md's
  # "Internal cluster DNS" section) instead of the public route. Bring the tunnel up
  # first (`wg-quick up <peer_conf_paths output>`).
  #
  # Overridden via -var for the other real execution context this root runs
  # in: the in-cluster Crossplane Workspace (gitops repo
  # services/platform/crossplane/config) passes this same address directly
  # (redundant with the default now, kept explicit since it's the whole
  # reason that Workspace exists: OpenBao not being reachable from outside
  # the cluster for a while after boot, so it can't depend on this default
  # ever changing back). A direct port-forward (`kubectl port-forward -n
  # openbao openbao-0 8200:8200`, requires Kubernetes permissions) is for
  # when the tunnel itself is the thing being debugged, or for a one-off
  # var.root_token bootstrap apply: -var vault_address=http://127.0.0.1:8200/.
  # The public route (https://openbao.staging.scalepack.fr/) still works too —
  # that's still there for human OIDC/UI login — just isn't the default
  # anymore.
  address = var.vault_address

  # Human admin, interactive browser login via Dex — dedicated block (unlike
  # kubernetes below, hashicorp/vault ~> 5.0 DOES ship auth_login_oidc,
  # confirmed against the installed 5.10.1 provider's own schema): opens a
  # local listener + browser tab itself, same flow `bao login -method=oidc`
  # uses under the hood (same underlying SDK) — not expressible via the
  # generic auth_login block at all, since this is a real interactive
  # redirect/callback dance, not a single synchronous POST. Against the SAME
  # already-registered redirect URI (gitops repo
  # services/platform/dex/chart's staticClients.openbao already lists
  # http://localhost:8250/oidc/callback — that's the CLI's own default local
  # callback, confirmed present since before this change, no new Dex config
  # needed). Skipped when var.root_token overrides (below).
  dynamic "auth_login_oidc" {
    for_each = var.root_token == null && var.vault_auth_method == "oidc" ? [1] : []
    content {
      role  = var.vault_oidc_role
      mount = "oidc"
    }
  }

  # No dedicated auth_login_kubernetes block in hashicorp/vault ~> 5.0
  # (confirmed against this provider version's own schema, 5.10.1) — plain
  # auth_login against auth/kubernetes/login instead, same shape as the
  # oidc block above. file() reads the pod's own projected ServiceAccount
  # token from the standard in-cluster path -- only ever evaluated when
  # this dynamic block's for_each actually produces the one element, i.e.
  # only inside the provider-opentofu pod where that file exists at all.
  # See vault_kubernetes_auth_backend_role.crossplane
  # (11-secrets/openbao/bootstrap/main.tf — a different root, see
  # var.vault_kubernetes_role's own comment above for why) for the role
  # this logs into. Skipped when var.root_token overrides (below).
  dynamic "auth_login" {
    for_each = var.root_token == null && var.vault_auth_method == "kubernetes" ? [1] : []
    content {
      path = "auth/kubernetes/login"
      parameters = {
        role = var.vault_kubernetes_role
        jwt  = file("/var/run/secrets/kubernetes.io/serviceaccount/token")
      }
    }
  }

  token = var.root_token
}

variable "root_token" {
  description = "OpenBao root/admin token — an explicit emergency/bootstrap override, NOT a normal execution path (see provider \"vault\" block's own comment): when set, takes priority over var.vault_auth_method entirely. Pass via TF_VAR_root_token, never a CLI flag, to keep it out of shell history."
  default     = null
  type        = string
  sensitive   = true
}
