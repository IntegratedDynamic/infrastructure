# 0 = never expires (Grafana's own sentinel for seconds_to_live) — mirrors
# service_account_token_ttl_days in 06-monitoring/grafana/bootstrap.
variable "mcp_service_account_token_ttl_days" {
  description = "Days before the mcp-claude-code service account token expires. 0 = never expires."
  type        = number
  default     = 0
}
