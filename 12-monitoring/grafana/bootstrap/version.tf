terraform {
  # Migrated to the dedicated Scaleway state bucket (00-foundation/scaleway,
  # state_buckets["monitoring_grafana_bootstrap"]).
  #
  # Prefix + workspace name now mirror this root's own path (2026-08-24
  # workspace-naming refacto, which also moved this domain from
  # 06-monitoring to 12-monitoring — postdating 10-cluster) — used to be
  # "monitoring/bootstrap/grafana" / "06-monitoring-grafana" (segment order
  # didn't even match the directory path). No terraform.workspace naming
  # coupling in this root, so this is a plain state relocation, zero
  # resource impact. Old state object left in place under the old
  # prefix/workspace, orphaned on purpose (never deleted).
  backend "s3" {
    bucket                      = "id-terraform-state-06-monitoring-grafana-bootstrap"
    region                      = "fr-par"
    workspace_key_prefix        = "12-monitoring/grafana/bootstrap"
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
    grafana = {
      source  = "grafana/grafana"
      version = "~> 4.0"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.0"
    }
  }
}

# 11-secrets/openbao/managed's own state — read directly instead of a
# hand-copied local.auto.tfvars value, same convention as every other
# cross-root credential in this repo (see that root's outputs.tf,
# grafana_admin_password). Plain S3 backend read, no provider needed for
# this data source. Workspace is "11-secrets-openbao-managed-dev" — that
# root's own actual workspace, distinct from
# 11-secrets/openbao/bootstrap's "11-secrets-openbao-bootstrap-dev" — don't
# assume the two roots under openbao/ share one workspace name.
# Credentials for the cross-root Scaleway state read below. Two execution
# contexts apply this root: an admin's machine (scw CLI configured) and
# the gitops repo's Argo Workflows terraform-apply CronWorkflow, which
# already sets SCW_ACCESS_KEY/SCW_SECRET_KEY as env vars but had no way to
# hand them to this data source -- confirmed live, silently returned empty
# credentials without this fallback (no error, since `scw` command
# substitution failing just yields an empty string), which then broke the
# cross-root state read below with a confusing "No valid credential
# sources found" error instead of failing at the actual source. Env vars
# now win when set; falling back to `scw config get` keeps the admin path
# exactly as it was. Same fix as 11-secrets/openbao/managed/main.tf's
# identical comment.
data "external" "scw_credentials" {
  program = ["sh", "-c", <<-EOT
    jq -n \
      --arg ak "$${SCW_ACCESS_KEY:-$(scw config get access-key)}" \
      --arg sk "$${SCW_SECRET_KEY:-$(scw config get secret-key)}" \
      '{access_key:$ak, secret_key:$sk}'
  EOT
  ]
}

locals {
  # See main.tf-equivalent comment elsewhere in the repo: shared technical
  # attributes for the cross-root Scaleway state read below, not "config" in
  # the meaningful sense. The actual target is parametrized via variables.tf
  # + env/, visible there instead of buried here.
  scaleway_state_backend = {
    region                      = "fr-par"
    access_key                  = data.external.scw_credentials.result.access_key
    secret_key                  = data.external.scw_credentials.result.secret_key
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
    use_path_style              = true
    endpoints = {
      s3 = "https://s3.fr-par.scw.cloud"
    }
  }
}

data "terraform_remote_state" "openbao_managed" {
  backend = "s3"
  config = merge(local.scaleway_state_backend, {
    bucket = var.openbao_managed_state_bucket
    key    = var.openbao_managed_state_key
  })
}

# Authenticates as Grafana's own admin via basic auth — the same admin
# credential 11-secrets/openbao/managed already generates and owns
# (kv/apps/grafana/admin). No chicken-and-egg like OpenBao's own bootstrap
# root_token: Grafana's admin password is already Terraform state elsewhere,
# so this root needs zero manually-supplied secrets.
#
# Defaults to Grafana's internal Service address (matches gitops repo's
# services/platform/monitoring's Grafana Service, namespace monitoring, port
# 80) — since infrastructure#81, reachable here through the WireGuard
# tunnel's internal-cluster DNS + proxy-dynamic sidecar (04-vpn/wireguard-
# site-to-site/README.md's "Internal cluster DNS" section), same pattern as the
# vault provider's own default in 11-secrets/openbao/{bootstrap,managed}.
# Bring the tunnel up first (`wg-quick up <peer_conf_paths output>`).
#
# Grafana's basic-auth API path specifically isn't gated behind the shared
# sso-guard edge policy (gitops repo's services/platform/monitoring/
# grafana-gateway deliberately bypasses it), so the public route
# (https://grafana.scalepack.fr/) still works fine too if the tunnel isn't
# up — just isn't the default anymore, for consistency with the vault
# provider's own address.
#
# Overridden via -var for the Argo Workflows CronWorkflow (gitops repo
# services/platform/argo-workflows) — passes this same address directly,
# redundant with the default now, kept explicit in that chart's values
# since it's the whole reason the override exists: confirmed live, the
# public route consistently times out ("context deadline exceeded") from
# inside the cluster (a pod reaching the cluster's own public ingress from
# behind it is a common hairpin-NAT gap), so it can't depend on this
# default ever changing back.
provider "grafana" {
  url  = var.grafana_url
  auth = "admin:${data.terraform_remote_state.openbao_managed.outputs.grafana_admin_password}"
}
