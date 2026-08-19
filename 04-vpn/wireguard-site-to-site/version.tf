terraform {
  # Migrated to the dedicated Scaleway state bucket (00-foundation/scaleway,
  # state_buckets["vpn_wireguard_site_to_site"]).
  backend "s3" {
    bucket                      = "id-terraform-state-04-vpn-wireguard-site-to-site"
    region                      = "fr-par"
    workspace_key_prefix        = "network/wireguard"
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
