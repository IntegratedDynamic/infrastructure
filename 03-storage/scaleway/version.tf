terraform {
  # Migrated to the dedicated Scaleway state bucket (00-foundation/scaleway,
  # state_buckets["storage_scaleway"]).
  #
  # Prefix + workspace name now mirror this root's own path (2026-08-24
  # workspace-naming refacto) — used to be "backup/scaleway" /
  # "03-backup-dev-bucket", leftover from this root's old name
  # 03-backup/scaleway (before backup/velero/thanos/loki/tempo/
  # argo_workflows_logs all landed here as tool buckets). NOTE: the
  # workspace name feeds every bucket's real Scaleway IAM application/policy
  # name (${prefix}-${terraform.workspace} in main.tf) — renaming it renames
  # those live resources in place (Scaleway API keys are tied to
  # application_id, not name, so this is not expected to rotate any
  # credential — verified via `terraform plan` before apply). Old state
  # object left in place under the old prefix/workspace, orphaned on purpose
  # (never deleted).
  backend "s3" {
    bucket                      = "id-terraform-state-03-storage-scaleway"
    region                      = "fr-par"
    workspace_key_prefix        = "03-storage/scaleway"
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
    scaleway = {
      source  = "scaleway/scaleway"
      version = "~> 2.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}

provider "scaleway" {}
