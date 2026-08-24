terraform {
  # Migrated to the dedicated Scaleway state bucket (00-foundation/scaleway,
  # state_buckets["vpn_wireguard_exit"]).
  #
  # Prefix + workspace name now mirror this root's own path (2026-08-24
  # workspace-naming refacto). No terraform.workspace naming coupling here
  # (pure local keypair generation), so this is a plain state relocation,
  # zero resource impact. Old state object left in place under the old
  # prefix/workspace, orphaned on purpose (never deleted).
  backend "s3" {
    bucket                      = "id-terraform-state-04-vpn-wireguard-exit"
    region                      = "fr-par"
    workspace_key_prefix        = "04-vpn/wireguard-exit"
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
    wireguard = {
      source  = "OJFord/wireguard"
      version = "~> 0.4"
    }
  }
}

# Pure local keypair generation — no API, no credentials to configure.
provider "wireguard" {}
