terraform {
  backend "s3" {
    bucket               = "id-terraform-state20260612164136440800000001"
    region               = "eu-west-3"
    workspace_key_prefix = "monitoring/managed/grafana"
    key                  = "terraform.tfstate"
    encrypt              = true
    use_lockfile         = true
  }

  required_providers {
    grafana = {
      source  = "grafana/grafana"
      version = "~> 4.0"
    }
  }
}

# 06-monitoring/grafana/bootstrap's own state — the terraform service
# account token this root authenticates as. Cross-root remote-state read,
# not a hand-copied value, same convention as every other cross-root
# credential in this repo.
data "terraform_remote_state" "grafana_bootstrap" {
  backend = "s3"
  config = {
    bucket = "id-terraform-state20260612164136440800000001"
    region = "eu-west-3"
    key    = "monitoring/bootstrap/grafana/06-monitoring-grafana/terraform.tfstate"
  }
}

# Already a bearer-style API token (grafana_service_account_token.key) — no
# "user:pass" formatting needed, unlike bootstrap's admin basic-auth.
provider "grafana" {
  url  = "https://grafana.scalepack.fr/"
  auth = data.terraform_remote_state.grafana_bootstrap.outputs.service_account_token
}
