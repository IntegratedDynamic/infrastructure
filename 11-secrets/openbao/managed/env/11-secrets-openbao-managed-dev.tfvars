# Everything sensitive (oidc_client_secret, var.root_token for an emergency
# apply) is in a gitignored local.auto.tfvars instead. This file names the
# terraform workspace
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

tailscale_bootstrap_state_bucket = "id-terraform-state-13-tailscale-bootstrap"
tailscale_bootstrap_state_key    = "13-tailscale/bootstrap/13-tailscale-bootstrap-dev/terraform.tfstate"

foundation_scaleway_state_bucket = "id-terraform-state-00-foundation-scaleway"
foundation_scaleway_state_key    = "00-foundation/scaleway/00-foundation-scaleway-dev/terraform.tfstate"

iam_bootstrap_scaleway_state_bucket = "id-terraform-state-01-iam-bootstrap-scaleway"
iam_bootstrap_scaleway_state_key    = "01-iam/bootstrap/scaleway/01-iam-bootstrap-scaleway-dev/terraform.tfstate"

# Kept in sync with 10-cluster/scaleway's own letsencrypt_staging (false since the
# switch to Let's Encrypt PROD certs; see that root's env tfvars). When true,
# OpenBao's oidc_discovery_ca_pem is the LE staging root and its server-side OIDC
# discovery call trusts ONLY that, so it rejects the prod certificate the gateway
# serves with "x509: certificate signed by unknown authority". This root was
# left at true when the cluster root flipped, which only surfaced when the
# discovery URL changed to authentik (the config is validated at write time).
# Flip both roots together when moving between staging and prod certs.
letsencrypt_staging = false

# var.domain -- must match 10-cluster/scaleway's own var.domain for this
# same cluster (see that root's env tfvars). Kept manually in sync, same
# pattern letsencrypt_staging above already uses -- no cross-root read for
# a plain string.
domain = "staging.scalepack.fr"
