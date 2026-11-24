terraform {
  # State lives in its own dedicated Scaleway bucket (00-foundation/scaleway,
  # state_buckets["sso_managed"]) -- same one-bucket-per-root layout every
  # other Scaleway-hosted root uses. Prefix + workspace name mirror this
  # root's own path (see the repo's "Backend keys are decoupled from paths"
  # convention).
  backend "s3" {
    bucket                      = "id-terraform-state-14-sso-managed"
    region                      = "fr-par"
    workspace_key_prefix        = "14-sso/managed"
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
    # Constraint kept in step with the other roots.
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    authentik = {
      source  = "goauthentik/authentik"
      version = "~> 2026.8"
    }
  }
}

# Authenticates with the akadmin API token authentik creates on its FIRST
# start from AUTHENTIK_BOOTSTRAP_TOKEN (11-secrets/openbao/managed's
# random_password.authentik_bootstrap_token -> kv/apps/authentik/credentials).
# It reaches this root as TF_VAR_authentik_token, never a committed value:
#
#   - in-cluster: the authentik-managed Crossplane Workspace (gitops repo,
#     services/platform/crossplane/config) maps it from the ESO-synced Secret
#     crossplane-authentik-token.
#   - locally: `export TF_VAR_authentik_token=$(bao kv get -field=AUTHENTIK_BOOTSTRAP_TOKEN kv/apps/authentik/credentials)`.
#
# `url` is the in-cluster Service address by default (the Workspace pod runs
# in the cluster), deliberately NOT the public sso.<domain> route: it does not
# depend on DNS propagation or the Gateway being up (same reasoning as
# 12-monitoring/grafana/managed's grafana_url).
provider "authentik" {
  url   = var.authentik_url
  token = var.authentik_token
}
