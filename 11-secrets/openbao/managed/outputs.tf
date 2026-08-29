# Grafana's admin password. This root owns it (random_password below,
# written to kv/apps/grafana/admin by resource "vault_kv_secret_v2"
# "grafana_admin"); 12-monitoring/grafana/managed authenticates as this
# admin to reconcile Grafana's config. That root does NOT read this output
# via terraform_remote_state, though — it takes the password as the env var
# TF_VAR_grafana_admin_password (ESO syncs kv/apps/grafana/admin into the
# crossplane-grafana-admin Secret in-cluster; `bao kv get` locally).
# Authenticating as the admin rather than a minted service-account token is
# deliberate: the token could stop working after a Velero restore while
# still showing valid (infra#82 mode 1), whereas this password is
# regenerated-and-repushed from this root's state on every restore. The
# output is kept as the documented owner-of-record for the value.
output "grafana_admin_password" {
  description = "Grafana admin password (kv/apps/grafana/admin's admin-password field)."
  sensitive   = true
  value       = random_password.grafana_admin_password.result
}
