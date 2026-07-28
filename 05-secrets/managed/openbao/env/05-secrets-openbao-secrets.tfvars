# No non-sensitive overrides needed — everything this root takes (AppRole
# creds, oidc_client_secret) is sensitive and lives in a gitignored
# local.auto.tfvars instead. This file exists to name the terraform workspace
# ("05-secrets-openbao-secrets"), per repo convention.
