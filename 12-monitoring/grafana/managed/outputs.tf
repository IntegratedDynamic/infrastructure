# Read locally via `terraform output -raw mcp_service_account_token` to
# configure the MCP server (~/.claude.json's grafana entry expands
# ${GRAFANA_SERVICE_ACCOUNT_TOKEN}, so `export GRAFANA_SERVICE_ACCOUNT_TOKEN=$(terraform
# output -raw mcp_service_account_token)` is the whole flow) — the only
# consumer is a human on their own machine. Used to also get pushed into
# OpenBao (apps/monitoring/grafana-mcp-token) for the same manual fetch —
# dropped 2026-08-14: state is always current post-apply, the OpenBao copy
# only updated when data_json_wo_version was bumped by hand, which is
# exactly the staleness that caused that day's confusion. No reason to
# keep a second, harder-to-keep-fresh copy of a value with one consumer.
output "mcp_service_account_token" {
  description = "Grafana service account token for the local MCP server config (sensitive)."
  value       = grafana_service_account_token.mcp_claude_code.key
  sensitive   = true
}
