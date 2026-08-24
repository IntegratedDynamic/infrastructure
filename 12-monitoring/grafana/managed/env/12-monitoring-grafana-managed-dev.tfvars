# mcp_service_account_token_ttl_days defaults sensibly (see variables.tf).
# This file names the terraform workspace ("12-monitoring-grafana-managed-dev")
# and carries the non-secret cross-root state bucket/key config below. Key
# updated 2026-08-24 (workspace-naming refacto) to point at the target
# root's new prefix/workspace.

grafana_bootstrap_state_bucket = "id-terraform-state-06-monitoring-grafana-bootstrap"
grafana_bootstrap_state_key    = "12-monitoring/grafana/bootstrap/12-monitoring-grafana-bootstrap-dev/terraform.tfstate"
