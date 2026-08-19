terraform {
  # Migrated to the dedicated Scaleway state bucket (00-foundation/scaleway,
  # state_buckets["monitoring_grafana_bootstrap"]).
  backend "s3" {
    bucket                      = "id-terraform-state-06-monitoring-grafana-bootstrap"
    region                      = "fr-par"
    workspace_key_prefix        = "monitoring/bootstrap/grafana"
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

# 05-secrets/openbao/managed's own state — read directly instead of a
# hand-copied local.auto.tfvars value, same convention as every other
# cross-root credential in this repo (see that root's outputs.tf,
# grafana_admin_password). Plain S3 backend read, no provider needed for
# this data source. Workspace is "05-secrets-openbao-secrets" — that root's
# own actual workspace (confirmed via `terraform workspace show`), distinct
# from 05-secrets/openbao/bootstrap's "05-secrets-openbao" — don't assume
# the two roots under openbao/ share one workspace name.
# Credentials for the cross-root Scaleway state read below: read straight
# from the scw CLI's own config (the same credentials `provider "scaleway"
# {}` already uses implicitly everywhere else) instead of requiring
# AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY set ambiently. Terraform's s3
# backend/data source has no notion of the scw CLI's own config format —
# this bridges the two credential systems automatically, so any admin who
# already has `scw` configured (a repo-wide prerequisite already) needs zero
# extra setup.
data "external" "scw_credentials" {
  program = ["sh", "-c", "jq -n --arg ak \"$(scw config get access-key)\" --arg sk \"$(scw config get secret-key)\" '{access_key:$ak, secret_key:$sk}'"]
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
# credential 05-secrets/openbao/managed already generates and owns
# (kv/apps/grafana/admin). No chicken-and-egg like OpenBao's own bootstrap
# root_token: Grafana's admin password is already Terraform state elsewhere,
# so this root needs zero manually-supplied secrets. Public route: Grafana's
# basic-auth API path isn't gated behind the shared sso-guard edge policy
# (gitops repo's services/platform/monitoring/grafana-gateway deliberately
# bypasses it, same reasoning the OpenBao vault provider's own comment gives
# for its public route), so no WireGuard tunnel is needed here.
provider "grafana" {
  url  = "https://grafana.scalepack.fr/"
  auth = "admin:${data.terraform_remote_state.openbao_managed.outputs.grafana_admin_password}"
}
