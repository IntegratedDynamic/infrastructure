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
    external = {
      source  = "hashicorp/external"
      version = "~> 2.0"
    }
  }
}

# 12-monitoring/grafana/bootstrap's own state — the terraform service
# account token this root authenticates as. Cross-root remote-state read,
# not a hand-copied value, same convention as every other cross-root
# credential in this repo.
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

data "terraform_remote_state" "grafana_bootstrap" {
  backend = "s3"
  config = merge(local.scaleway_state_backend, {
    bucket = var.grafana_bootstrap_state_bucket
    key    = var.grafana_bootstrap_state_key
  })
}

# Already a bearer-style API token (grafana_service_account_token.key) — no
# "user:pass" formatting needed, unlike bootstrap's admin basic-auth.
# See that root's version.tf for why `url` is a variable, not a literal --
# same reason applies here.
provider "grafana" {
  url  = var.grafana_url
  auth = data.terraform_remote_state.grafana_bootstrap.outputs.service_account_token
}
