terraform {
  # Migrated to the dedicated Scaleway state bucket (00-foundation/scaleway,
  # state_buckets["monitoring_grafana_managed"]).
  #
  # Prefix + workspace name now mirror this root's own path (2026-08-24
  # workspace-naming refacto, which also moved this domain from
  # 06-monitoring to 12-monitoring — postdating 10-cluster) — used to be
  # "monitoring/managed/grafana" / "06-monitoring-grafana" (segment order
  # didn't even match the directory path, and this workspace name literally
  # collided with the bootstrap root's — different buckets, so no actual
  # clash, but confusing). No terraform.workspace naming coupling in this
  # root, so this is a plain state relocation, zero resource impact. Old
  # state object left in place under the old prefix/workspace, orphaned on
  # purpose (never deleted).
  backend "s3" {
    bucket                      = "id-terraform-state-06-monitoring-grafana-managed"
    region                      = "fr-par"
    workspace_key_prefix        = "12-monitoring/grafana/managed"
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
    grafana = {
      source  = "grafana/grafana"
      version = "~> 4.0"
    }
    # infra#82 restore-adopt probes in main.tf hit Grafana's live API for
    # the current ids of the mcp-claude-code SA and the data sources, so a
    # config-driven `import` can adopt them when this root's state is fresh
    # but Grafana already carries them (post-restore). A plugin, so it runs
    # in the provider-opentofu runtime image with nothing baked in.
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
  }
}

# The `grafana` provider authenticates as Grafana's own admin via basic
# auth. The password is 11-secrets/openbao/managed's
# random_password.grafana_admin_password (backing kv/apps/grafana/admin) —
# but it reaches this root as the env var TF_VAR_grafana_admin_password,
# NOT a cross-root terraform_remote_state read:
#
#   - in-cluster: the Crossplane opentofu.upbound.io/Workspace for this root
#     (gitops repo services/platform/crossplane/config) maps it from the
#     ESO-synced Secret `crossplane-grafana-admin` (OpenBao kv/apps/grafana/
#     admin, same ClusterSecretStore every other ExternalSecret uses).
#   - locally: `export TF_VAR_grafana_admin_password=$(bao kv get -field=admin-password kv/apps/grafana/admin)`.
#
# Passing the credential straight in is deliberate: there is no separate
# 12-monitoring/grafana/bootstrap root anymore (it only minted a `terraform`
# SA token that could stop authenticating after a Velero restore while
# still showing valid — infra#82 mode 1), and reading openbao/managed's
# whole state blob over S3 just to pull one password out is a detour the
# reconcile loop's env-var wiring already avoids for every other secret it
# needs.
#
# `url` is a variable, not a literal, for the same reason the retired
# bootstrap root gave: it defaults to Grafana's internal Service address
# (http://grafana.monitoring.svc:80/, reachable here through the WireGuard
# tunnel's internal-cluster DNS — 04-vpn/wireguard-site-to-site, infra#81),
# but the in-cluster Workspace overrides it via TF_VAR_grafana_url because a
# pod reaching the cluster's own public ingress from behind it hits a
# hairpin-NAT gap ("context deadline exceeded"). Grafana's basic-auth API
# path isn't behind the sso-guard edge policy, so the public route
# (https://grafana.scalepack.fr/) still works if the tunnel is down — just
# isn't the default.
provider "grafana" {
  url  = var.grafana_url
  auth = "admin:${var.grafana_admin_password}"
}
