# Names the OpenTofu workspace ("12-monitoring-grafana-managed-dev").
#
# This root has no non-secret cross-root config to carry: `grafana_url`
# defaults sensibly (see variables.tf) and is overridden per-run by
# TF_VAR_grafana_url in-cluster; the admin password comes via
# TF_VAR_grafana_admin_password (a secret — never a committed value). So
# `mcp_service_account_token_ttl_days`'s default is all that applies here,
# and this file is intentionally otherwise empty.
