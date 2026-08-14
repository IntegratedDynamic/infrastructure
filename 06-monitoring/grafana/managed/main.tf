# mcp-claude-code — the Grafana MCP server's (github.com/grafana/mcp-grafana)
# own service account, used by Claude Code locally to query dashboards,
# datasources, and alerts. role = "Editor" per that project's own
# recommendation: enough for its typical toolset without full Admin.
resource "grafana_service_account" "mcp_claude_code" {
  name = "mcp-claude-code"
  role = "Editor"
}

resource "grafana_service_account_token" "mcp_claude_code" {
  name                = "mcp-claude-code"
  service_account_id  = grafana_service_account.mcp_claude_code.id
  seconds_to_live     = var.mcp_service_account_token_ttl_days * 24 * 3600
}

# apps/monitoring/grafana-mcp-token — deliberately NOT synced into the
# cluster by anything (no ESO ExternalSecret reads this): the only consumer
# is a human (me) fetching it directly from OpenBao to configure the MCP
# server locally (`claude mcp add-json`), same rationale as
# 05-secrets/openbao/managed's apps/wireguard/confs.
resource "vault_kv_secret_v2" "grafana_mcp_token" {
  mount = "kv"
  name  = "apps/monitoring/grafana-mcp-token"

  data_json_wo = jsonencode({
    token = grafana_service_account_token.mcp_claude_code.key
  })
  data_json_wo_version = 1
}
