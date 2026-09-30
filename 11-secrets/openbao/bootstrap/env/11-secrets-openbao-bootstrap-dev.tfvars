# Names the terraform workspace ("11-secrets-openbao-bootstrap-dev") — no
# variables actually need a value here. var.vault_address defaults to the
# in-cluster Service (override with -var for a kubectl port-forward);
# var.root_token has no default and is never committed — pass it via
# TF_VAR_root_token.
