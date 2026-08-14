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
    vault = {
      source  = "hashicorp/vault"
      version = "~> 5.0"
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

# 05-secrets/openbao/bootstrap's own state — the SAME `terraform` AppRole
# 05-secrets/openbao/managed itself authenticates as. Its policy already
# grants kv/data|metadata/apps/* broadly (create/read/update/list), so
# writing this root's own secret (apps/monitoring/grafana-mcp-token, see
# main.tf) needs no new OpenBao-side policy — reusing the existing identity
# is simpler than minting a second one for the same capability.
data "terraform_remote_state" "openbao_bootstrap" {
  backend = "s3"
  config = {
    bucket = "id-terraform-state20260612164136440800000001"
    region = "eu-west-3"
    key    = "secrets/bootstrap/openbao/05-secrets-openbao/terraform.tfstate"
  }
}

provider "vault" {
  # Same address/rationale as 05-secrets/openbao/managed's own vault
  # provider — see that root's version.tf for the full split-DNS/WireGuard
  # explanation.
  address = "https://openbao.scalepack.fr/"

  auth_login {
    path = "auth/approle/login"
    parameters = {
      role_id   = data.terraform_remote_state.openbao_bootstrap.outputs.role_id
      secret_id = data.terraform_remote_state.openbao_bootstrap.outputs.secret_id
    }
  }
}
