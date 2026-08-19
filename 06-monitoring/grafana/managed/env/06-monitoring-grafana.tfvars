# mcp_service_account_token_ttl_days defaults sensibly (see variables.tf).
# This file names the terraform workspace ("06-monitoring-grafana") and
# carries the non-secret cross-root state bucket/key config below.

grafana_bootstrap_state_bucket = "id-terraform-state-06-monitoring-grafana-bootstrap"
grafana_bootstrap_state_key    = "monitoring/bootstrap/grafana/06-monitoring-grafana/terraform.tfstate"
