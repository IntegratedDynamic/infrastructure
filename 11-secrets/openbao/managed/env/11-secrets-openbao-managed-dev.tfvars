# Everything sensitive (AppRole creds, oidc_client_secret) is in a gitignored
# local.auto.tfvars instead. This file names the terraform workspace
# ("11-secrets-openbao-managed-dev") and carries the non-secret cross-root
# state bucket/key config below — see
# 00-foundation/scaleway/env/00-foundation-scaleway-dev.tfvars for the full
# bucket list. Keys updated 2026-08-24 (workspace-naming refacto) to point
# at each target root's new prefix/workspace.

dns_scaleway_state_bucket = "id-terraform-state-01-iam-workload-scaleway"
dns_scaleway_state_key    = "01-iam/workload/scaleway/01-iam-workload-scaleway-dev/terraform.tfstate"

backup_scaleway_state_bucket = "id-terraform-state-03-storage-scaleway"
backup_scaleway_state_key    = "03-storage/scaleway/03-storage-scaleway-dev/terraform.tfstate"

wireguard_state_bucket = "id-terraform-state-04-vpn-wireguard-site-to-site"
wireguard_state_key    = "04-vpn/wireguard-site-to-site/04-vpn-wireguard-site-to-site-dev/terraform.tfstate"

wireguard_exit_state_bucket = "id-terraform-state-04-vpn-wireguard-exit"
wireguard_exit_state_key    = "04-vpn/wireguard-exit/04-vpn-wireguard-exit-dev/terraform.tfstate"

openbao_bootstrap_state_bucket = "id-terraform-state-05-secrets-openbao-bootstrap"
openbao_bootstrap_state_key    = "11-secrets/openbao/bootstrap/11-secrets-openbao-bootstrap-dev/terraform.tfstate"

foundation_scaleway_state_bucket = "id-terraform-state-00-foundation-scaleway"
foundation_scaleway_state_key    = "00-foundation/scaleway/00-foundation-scaleway-dev/terraform.tfstate"

iam_bootstrap_scaleway_state_bucket = "id-terraform-state-01-iam-bootstrap-scaleway"
iam_bootstrap_scaleway_state_key    = "01-iam/bootstrap/scaleway/01-iam-bootstrap-scaleway-dev/terraform.tfstate"

# Standing state, kept in sync with 10-cluster/scaleway's own
# letsencrypt_staging = true (see that root's env tfvars for the full "why":
# gateway/cert-restore restores a staging-issued wildcard cert on every
# boot, so the whole platform runs on LE staging). This flips OpenBao's own
# oidc_discovery_ca_pem to the LE staging root so its server-side OIDC
# discovery call to auth.scalepack.fr trusts the cert envoy-gateway
# actually serves, instead of failing "x509: certificate signed by unknown
# authority". Flip both roots back together if/when moving to prod certs.
letsencrypt_staging = true
