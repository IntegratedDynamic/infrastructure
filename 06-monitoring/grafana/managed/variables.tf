# 0 = never expires (Grafana's own sentinel for seconds_to_live) — mirrors
# service_account_token_ttl_days in 06-monitoring/grafana/bootstrap.
variable "mcp_service_account_token_ttl_days" {
  description = "Days before the mcp-claude-code service account token expires. 0 = never expires."
  type        = number
  default     = 0
}

# ── Cross-root state reads (Scaleway state buckets, see 00-foundation/scaleway) ──

variable "grafana_bootstrap_state_bucket" {
  description = "Scaleway bucket holding 06-monitoring/grafana/bootstrap's remote state."
  type        = string
}

variable "grafana_bootstrap_state_key" {
  description = "Object key for 06-monitoring/grafana/bootstrap's state within grafana_bootstrap_state_bucket."
  type        = string
}
