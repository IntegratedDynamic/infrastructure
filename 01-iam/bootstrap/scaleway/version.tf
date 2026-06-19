terraform {
  backend "s3" {
    bucket = "id-terraform-state20260612164136440800000001"
    region = "eu-west-3"
    # Prefix kept as "github-ci" (≠ this root's path ci/10-scaleway/) on purpose:
    # the state key is decoupled from the directory, so the repo restructure was
    # a pure move with zero state migration.
    workspace_key_prefix = "github-ci"
    key                  = "terraform.tfstate"
    encrypt              = true
    use_lockfile         = true
  }



  required_providers {
    scaleway = {
      source  = "scaleway/scaleway"
      version = "~> 2.0"
    }
    infisical = {
      source  = "infisical/infisical"
      version = "~> 0.16"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}

# Creds, region and project_id come from the scw CLI config (like the other roots).
provider "scaleway" {}
# Without `auth.oidc`, infisical will not try to consume OIDC environment variables, even if present, and will only look for generic auth environment variables. 
provider "infisical" {
  auth = { 
    ## Uncomment `universal` and comment `oidc` when running terraform locally, .
    ## By default, even with `INFISICAL_UNIVERSAL_AUTH_CLIENT_XXXX` environment variable, due to `auth.oidc` being present, infisical provider expect OIDC configuration, and nothing else.
    # universal = {} 
    oidc = {} 
  }
}
