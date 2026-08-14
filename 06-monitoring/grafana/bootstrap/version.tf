terraform {
  backend "s3" {
    bucket               = "id-terraform-state20260612164136440800000001"
    region               = "eu-west-3"
    workspace_key_prefix = "monitoring/bootstrap/grafana"
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

# 05-secrets/openbao/managed's own state — read directly instead of a
# hand-copied local.auto.tfvars value, same convention as every other
# cross-root credential in this repo (see that root's outputs.tf,
# grafana_admin_password). Plain S3 backend read, no provider needed for
# this data source.
data "terraform_remote_state" "openbao_managed" {
  backend = "s3"
  config = {
    bucket = "id-terraform-state20260612164136440800000001"
    region = "eu-west-3"
    key    = "secrets/managed/openbao/05-secrets-openbao/terraform.tfstate"
  }
}

# Authenticates as Grafana's own admin via basic auth — the same admin
# credential 05-secrets/openbao/managed already generates and owns
# (kv/apps/grafana/admin). No chicken-and-egg like OpenBao's own bootstrap
# root_token: Grafana's admin password is already Terraform state elsewhere,
# so this root needs zero manually-supplied secrets. Public route: Grafana's
# basic-auth API path isn't gated behind the shared sso-guard edge policy
# (gitops repo's services/platform/monitoring/grafana-gateway deliberately
# bypasses it, same reasoning the OpenBao vault provider's own comment gives
# for its public route), so no WireGuard tunnel is needed here.
provider "grafana" {
  url  = "https://grafana.scalepack.fr/"
  auth = "admin:${data.terraform_remote_state.openbao_managed.outputs.grafana_admin_password}"
}
