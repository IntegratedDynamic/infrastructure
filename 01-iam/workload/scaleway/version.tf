terraform {
  # Migrated to the dedicated Scaleway state bucket (00-foundation/scaleway,
  # state_buckets["iam_workload_scaleway"]).
  backend "s3" {
    bucket = "id-terraform-state-01-iam-workload-scaleway"
    region = "fr-par"
    # Prefix + workspace name now mirror this root's own path (2026-08-24
    # workspace-naming refacto) — used to be "dns/scaleway", a leftover from
    # this root's old location 04-dns/scaleway/ (moved here since this root
    # owns no DNS resource, only the workload identities below). NOTE: the
    # workspace name feeds real Scaleway IAM application/policy names below
    # (${each.key}-${terraform.workspace}) — renaming it renames those live
    # resources in place (Scaleway API keys are tied to application_id, not
    # name, so this is not expected to rotate any credential — verified via
    # `terraform plan` before apply). Old state object left in place under
    # the old prefix/workspace, orphaned on purpose (never deleted).
    workspace_key_prefix        = "01-iam/workload/scaleway"
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

# Creds, region and project_id come from the scw CLI config (like the other roots).
provider "scaleway" {}
