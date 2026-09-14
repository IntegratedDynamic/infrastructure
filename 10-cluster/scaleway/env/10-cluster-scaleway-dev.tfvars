cluster_name = "scaleway-homelab"
node_count   = 2

# THROWAWAY test override — pins both repos for live validation
# (infra#107 / gitops#58), plus gitops#57 (openbao-init restore-marker
# fix): the first apply attempt on this branch (run 34840560961) hit the
# PRE-EXISTING openbao-init race bug #57 already fixes -- OpenBao ended up
# initialized-but-empty (kubernetes auth never configured), so ESO's
# ClusterSecretStore 403'd and wait-secrets-healthy timed out at 35m. #58's
# grafana-admin ESO path can't be validated without OpenBao actually
# healthy, so gitops_revision now points at a throwaway branch merging
# #57 into #58 (test/grafana-admin-auth-combined). Drop before any merge to
# main; never commit this pin on main itself.
infra_revision  = "fix/grafana-workspace-adopt-existing-sa"
gitops_revision = "test/grafana-admin-auth-combined"

# This homelab runs on Let's Encrypt STAGING, not prod, as its standing
# state (see var.letsencrypt_staging). Two reasons, both confirmed live:
#  1. gateway/cert-restore restores the scalepack.fr wildcard TLS Secret
#     from the latest Velero backup on every fresh boot -- and every
#     backup taken so far is from a staging-issued cert. cert-manager
#     treats the restored Secret as satisfying the Certificate (right
#     SANs, valid dates) and does NOT re-issue against letsencrypt-prod,
#     so envoy-gateway ends up serving a staging cert regardless of which
#     ClusterIssuer is "active". Running the whole platform on staging
#     keeps ArgoCD/OpenBao's server-side OIDC calls to auth.scalepack.fr
#     trusting the right root (their rootCA / oidc_discovery_ca_pem
#     overrides only kick in when this flag is true) instead of failing
#     "x509: certificate signed by unknown authority".
#  2. This cluster is rebuilt from scratch often enough that LE's prod
#     rate limit (5 duplicate certs/week) is a real risk; staging's
#     limits are far higher.
# Flip to false only alongside a deliberate move to prod certs (fresh
# prod-issued backup, or cert-restore disabled).
letsencrypt_staging = true

# Cross-root state reads — see 00-foundation/scaleway/env/00-foundation-scaleway-dev.tfvars
# for the full bucket list. Keys updated 2026-08-24 (workspace-naming
# refacto) to point at each target root's new prefix/workspace.
backup_scaleway_state_bucket    = "id-terraform-state-03-storage-scaleway"
backup_scaleway_state_key       = "03-storage/scaleway/03-storage-scaleway-dev/terraform.tfstate"
openbao_unseal_aws_state_bucket = "id-terraform-state-02-encryption-aws"
openbao_unseal_aws_state_key    = "02-encryption/aws/02-encryption-aws-dev/terraform.tfstate"
dns_scaleway_state_bucket       = "id-terraform-state-01-iam-workload-scaleway"
dns_scaleway_state_key          = "01-iam/workload/scaleway/01-iam-workload-scaleway-dev/terraform.tfstate"
