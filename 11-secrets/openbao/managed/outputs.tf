# Read by 12-monitoring/grafana/bootstrap's own provider "grafana" block —
# that root needs to authenticate as Grafana's admin to create its own
# service-account trust anchor, and this root already owns that credential
# (kv/apps/grafana/admin, see resource "vault_kv_secret_v2" "grafana_admin"
# above). Cross-root terraform_remote_state read instead of a manually
# re-entered value, same convention as every other cross-root credential in
# this repo (see this file's own header comment, or 03-storage/scaleway's
# outputs consumed just above).
output "grafana_admin_password" {
  description = "Grafana admin password (kv/apps/grafana/admin's admin-password field)."
  sensitive   = true
  value       = random_password.grafana_admin_password.result
}
