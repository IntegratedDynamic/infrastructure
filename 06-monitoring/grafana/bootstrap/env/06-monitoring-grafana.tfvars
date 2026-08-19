# service_account_token_ttl_days defaults sensibly (see variables.tf). This
# file names the terraform workspace ("06-monitoring-grafana") and carries
# the non-secret cross-root state bucket/key config below.

openbao_managed_state_bucket = "id-terraform-state-05-secrets-openbao-managed"
openbao_managed_state_key    = "secrets/managed/openbao/05-secrets-openbao-secrets/terraform.tfstate"
