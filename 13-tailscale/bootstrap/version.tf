terraform {
  # New domain (13-tailscale/bootstrap) -- own dedicated state bucket in
  # 00-foundation/scaleway's state_buckets map (bucket_name =
  # "id-terraform-state-13-tailscale-bootstrap"), same one-bucket-per-root
  # pattern every other root uses.
  backend "s3" {
    bucket                      = "id-terraform-state-13-tailscale-bootstrap"
    region                      = "fr-par"
    workspace_key_prefix        = "13-tailscale/bootstrap"
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
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    tailscale = {
      source  = "tailscale/tailscale"
      version = "~> 0.29"
    }
  }
}

# Bootstrap API key comes from a gitignored *.auto.tfvars (per-developer,
# not shared) -- see README's "Bootstrap credentials" section for how to
# generate one in the Tailscale admin console.
provider "tailscale" {
  api_key = var.api_key
  tailnet = var.tailnet
}
