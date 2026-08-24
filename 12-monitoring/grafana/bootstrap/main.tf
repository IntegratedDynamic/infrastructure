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
}

resource "grafana_service_account_token" "terraform" {
  name               = "terraform"
  service_account_id = grafana_service_account.terraform.id
  seconds_to_live    = var.service_account_token_ttl_days * 24 * 3600
}
