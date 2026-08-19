# Everything sensitive (AppRole creds, oidc_client_secret) is in a gitignored
# local.auto.tfvars instead. This file names the terraform workspace
# ("05-secrets-openbao-secrets") and carries the non-secret cross-root state
# bucket/key config below — see 00-foundation/scaleway/env/00-remote-state-backend.tfvars
# for the full bucket list.

dns_scaleway_state_bucket = "id-terraform-state-01-iam-workload-scaleway"
dns_scaleway_state_key    = "dns/scaleway/04-dns-scaleway/terraform.tfstate"

backup_scaleway_state_bucket = "id-terraform-state-03-storage-scaleway"
backup_scaleway_state_key    = "backup/scaleway/03-backup-dev-bucket/terraform.tfstate"

wireguard_state_bucket = "id-terraform-state-04-vpn-wireguard-site-to-site"
wireguard_state_key    = "network/wireguard/04-network-wireguard/terraform.tfstate"

wireguard_exit_state_bucket = "id-terraform-state-04-vpn-wireguard-exit"
wireguard_exit_state_key    = "network/wireguard-exit/04-network-wireguard-exit/terraform.tfstate"

openbao_bootstrap_state_bucket = "id-terraform-state-05-secrets-openbao-bootstrap"
openbao_bootstrap_state_key    = "secrets/bootstrap/openbao/05-secrets-openbao/terraform.tfstate"
