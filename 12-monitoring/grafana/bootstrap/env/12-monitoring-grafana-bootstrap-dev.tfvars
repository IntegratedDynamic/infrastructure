# service_account_token_ttl_days defaults sensibly (see variables.tf). This
# file names the terraform workspace ("12-monitoring-grafana-bootstrap-dev")
# and carries the non-secret cross-root state bucket/key config below. Key
# updated 2026-08-24 (workspace-naming refacto) to point at the target
# root's new prefix/workspace.

openbao_managed_state_bucket = "id-terraform-state-05-secrets-openbao-managed"
openbao_managed_state_key    = "11-secrets/openbao/managed/11-secrets-openbao-managed-dev/terraform.tfstate"
