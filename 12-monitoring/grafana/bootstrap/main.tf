# ── infra#82 mode-1 self-heal, folded in (issue #101) ──────────────────────
#
# grafana_service_account_token.terraform can go dead -- Grafana rejects it
# with "invalid API key" -- while still existing and showing
# not-expired/not-revoked in Grafana's own metadata. A cluster rebuild that
# restores Grafana's PVC from an older Velero snapshot did exactly this
# 2026-08-23. A plain `apply` loop can never notice: the provider can only
# read whether the token resource still exists, never read its secret value
# back to test it.
#
# The Argo Workflows preflight that used to curl the token and force a
# `-replace` on a 401 is gone (issue #101 -- Crossplane's Workspace has no
# pre-apply hook). Replicated here in config: probe Grafana AS ADMIN (basic
# auth, creds from openbao/managed's state -- deliberately NOT the SA token,
# so there's no dependency cycle) for the live numeric id of the `terraform`
# service account, and drive replacement of the SA + token off any change to
# it via replace_triggered_by. A restore that dropped the SA, or recreated
# it under a new id, flips terraform_data.grafana_sa_liveness and both
# resources recreate unattended.
#
# hashicorp/http surfaces a non-2xx response as data, not a Terraform error,
# so a down / freshly-restored Grafana is observable here rather than a hard
# plan failure -- Crossplane's Workspace just retries on its own backoff
# until Grafana answers. (A genuine connection refusal IS still a hard
# error, same as the provider "grafana" block itself would hit -- no
# regression for a local `tofu plan` run without the tunnel up.)
data "http" "grafana_service_accounts" {
  url = "${var.grafana_url}api/serviceaccounts/search?query=terraform&perpage=100"
  request_headers = {
    Authorization = "Basic ${base64encode("admin:${data.terraform_remote_state.openbao_managed.outputs.grafana_admin_password}")}"
    Accept        = "application/json"
  }
}

locals {
  # Live numeric id of the "terraform" service account, or -1 when Grafana
  # doesn't return it (down, admin auth rejected, or a restore wiped it).
  # Any transition of this value recreates the SA + its token below.
  grafana_terraform_sa_live_id = try(
    one([
      for sa in jsondecode(data.http.grafana_service_accounts.response_body).serviceAccounts :
      sa.id if sa.name == "terraform"
    ]),
    -1,
  )
}

resource "terraform_data" "grafana_sa_liveness" {
  input = local.grafana_terraform_sa_live_id
}

# ── The trust anchor itself ───────────────────────────────────────────────
#
# Trust anchor for future Terraform-managed Grafana configuration: a service
# account scoped to *creating further Grafana resources* (dashboards, other
# service accounts, OIDC config, ...), not any one specific integration.
# Mirrors 11-secrets/openbao/bootstrap's AppRole role exactly — same
# "admin mints the one identity everything else authenticates as" pattern.
#
# role = "Admin": Grafana's service-account roles are coarse (Viewer/Editor/
# Admin, no fine-grained per-path ACL like Vault/OpenBao policies) —
# creating other service accounts/tokens requires Admin. Same reasoning as
# OpenBao's own terraform policy getting sudo on sys/mounts/sys/auth: this
# identity needs elevated rights to bootstrap structure, even though it's
# still narrower than the real human admin account.
resource "grafana_service_account" "terraform" {
  name = "terraform"
  role = "Admin"

  lifecycle {
    replace_triggered_by = [terraform_data.grafana_sa_liveness]
  }
}

resource "grafana_service_account_token" "terraform" {
  name               = "terraform"
  service_account_id = grafana_service_account.terraform.id
  seconds_to_live    = var.service_account_token_ttl_days * 24 * 3600

  # Recreated whenever the SA is (new service_account_id) AND directly on a
  # liveness transition, for the "SA id unchanged but token secret is dead"
  # shape a new SA id wouldn't catch on its own.
  lifecycle {
    replace_triggered_by = [terraform_data.grafana_sa_liveness]
  }
}

# Residual case the id probe above structurally can't see: the SA keeps its
# numeric id but the token's stored hash no longer matches state (a partial
# restore). Not silently tolerated -- this fails as a check warning on
# `tofu plan` / the Crossplane Workspace's status, the cue for a one-off
#   tofu apply -replace=grafana_service_account_token.terraform
# See README.md's "Self-heal" section.
check "grafana_terraform_token_authenticates" {
  data "http" "grafana_token_probe" {
    url = "${var.grafana_url}api/serviceaccounts/search?perpage=1"
    request_headers = {
      Authorization = "Bearer ${grafana_service_account_token.terraform.key}"
    }
  }

  assert {
    condition     = data.http.grafana_token_probe.status_code == 200
    error_message = "grafana/bootstrap's own service-account token no longer authenticates (HTTP ${data.http.grafana_token_probe.status_code}) -- run: tofu apply -replace=grafana_service_account_token.terraform"
  }
}
