# No built-in expiry enforced by Grafana on service account tokens by
# default — repo convention, mirrors service_account_token_ttl_days in
# 06-monitoring/grafana/bootstrap.
variable "mcp_service_account_token_ttl_days" {
  description = "Rotation window (days) for the mcp-claude-code service account token."
  type        = number
  default     = 90
}
