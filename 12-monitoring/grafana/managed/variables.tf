# 0 = never expires (Grafana's own sentinel for seconds_to_live). Set a
# positive value to opt into rotation of the mcp-claude-code token.
variable "mcp_service_account_token_ttl_days" {
  description = "Days before the mcp-claude-code service account token expires. 0 = never expires."
  type        = number
  default     = 0
}

# Grafana's admin password (kv/apps/grafana/admin's admin-password field,
# originated by 11-secrets/openbao/managed). Supplied as the env var
# TF_VAR_grafana_admin_password — from the ESO-synced `crossplane-grafana-admin`
# Secret in-cluster, or `bao kv get` locally. No default, no tfvars entry:
# it's a secret and must never land in a committed file. See version.tf.
variable "grafana_admin_password" {
  description = "Grafana admin password the grafana provider authenticates with (env: TF_VAR_grafana_admin_password)."
  type        = string
  sensitive   = true
}

# See version.tf's provider "grafana" block for why this is a variable.
variable "grafana_url" {
  description = "URL the grafana provider authenticates against."
  type        = string
  default     = "http://grafana.monitoring.svc:80/"
}
