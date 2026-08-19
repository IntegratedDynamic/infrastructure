terraform {
  # Migrated to the dedicated Scaleway state bucket (00-foundation/scaleway,
  # state_buckets["monitoring_grafana_managed"]).
  backend "s3" {
    bucket                      = "id-terraform-state-06-monitoring-grafana-managed"
    region                      = "fr-par"
    workspace_key_prefix        = "monitoring/managed/grafana"
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

# 06-monitoring/grafana/bootstrap's own state — the terraform service
# account token this root authenticates as. Cross-root remote-state read,
# not a hand-copied value, same convention as every other cross-root
# credential in this repo.
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

data "terraform_remote_state" "grafana_bootstrap" {
  backend = "s3"
  config = merge(local.scaleway_state_backend, {
    bucket = var.grafana_bootstrap_state_bucket
    key    = var.grafana_bootstrap_state_key
  })
}

# Already a bearer-style API token (grafana_service_account_token.key) — no
# "user:pass" formatting needed, unlike bootstrap's admin basic-auth.
provider "grafana" {
  url  = "https://grafana.scalepack.fr/"
  auth = data.terraform_remote_state.grafana_bootstrap.outputs.service_account_token
}
