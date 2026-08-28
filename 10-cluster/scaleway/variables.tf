# # Infisical provide many way to authenticate.
# # You can use `infisical_client_id` and `infisical_client_secret` when running terraform locally
# # Or use `infisical_oidc_identity_id` when OIDC integration is available.
# variable "infisical_client_id" {
#   type    = string
#   default = ""
# }

# variable "infisical_client_secret" {
#   type      = string
#   default   = ""
#   sensitive = true
# }

# variable "infisical_oidc_identity_id" {
#   description = "Infisical OIDC machine-identity ID. When set, the provider authenticates via GitHub-OIDC; when empty, via universal auth."
#   type        = string
#   default     = ""
# }

variable "k8s_version" {
  type    = string
  default = "1.35"
}

variable "node_count" {
  type    = number
  default = 1
}

variable "cluster_name" {
  description = "The cluster name"
  type        = string
  default     = "scaleway-homelab"
}

# Branch of the gitops repo ArgoCD's `bootstrap` (and every platform
# domain's own child Applications) pull from. "Override on your own branch,
# test end-to-end, never merge that change" DevX trick -- if the named
# branch doesn't actually exist on gitops (never pushed, or merged and
# deleted since), argocd.tf's effective_gitops_revision local falls back to
# "main" itself at apply time, since ArgoCD has no such fallback of its
# own (an unresolvable targetRevision just sits in ComparisonError).
variable "gitops_revision" {
  type    = string
  default = "main"
}

# Revision of THIS repo (infrastructure) ArgoCD's secrets-apps/monitoring-apps/
# backups-apps Applications pull platform-apps/ from — see argocd.tf's
# argocd_platform_apps helm_release. Same "override on your own branch to
# test end-to-end, never merge that change" DevX trick as gitops_revision
# above (same apply-time fallback-to-main too, see argocd.tf's
# effective_infra_revision); MUST stay "main" on origin/main.
variable "infra_revision" {
  type    = string
  default = "main"
}

variable "update_kubeconfig" {
  type        = bool
  default     = false
  description = "Set to true when using locally to automatically update you ~/.kube/config. Require `kubectl` and `scw` installed & configured."
}

# Feature flag (2026-08-27, infra#99): switches gateway-config's ACME
# ClusterIssuer from letsencrypt-prod to letsencrypt-staging, and injects
# the Let's Encrypt staging root CA (files/letsencrypt-staging-root-ca.pem
# -- confirmed against Let's Encrypt's own docs that the ROOT, not an
# intermediate, is the one safe to pin long-term) into every component that
# makes real server-side HTTPS calls to the public https://auth.scalepack.fr
# for OIDC (ArgoCD, Grafana, OpenBao -- confirmed via each one's actual
# config; argo-workflows and Dex itself confirmed NOT to need this, see
# argocd.tf's own comments). Exists because staging has a vastly higher
# rate limit than production's real "5 duplicate certs per exact identifier
# set per 168h" -- confirmed live (2026-08-27) that a burst of same-week
# from-scratch cluster rebuilds (each one forcing a brand-new ACME issuance
# with no prior Velero backup to restore from) exhausts that limit for
# real. Default false: leaves every existing resource untouched -- flip
# only for a burst of live-testing rebuilds, same "override on your own
# branch, never merge the flip" spirit as gitops_revision/infra_revision
# above.
variable "letsencrypt_staging" {
  type        = bool
  default     = false
  description = "Use Let's Encrypt staging (higher rate limit, untrusted CA) instead of production for the platform's public wildcard cert. Also injects the staging root CA into ArgoCD/Grafana/OpenBao so their own OIDC calls to auth.scalepack.fr still work."
}


# variable "gitops_revision" {
#   type    = string
#   default = "main"
# }

variable "argocd_admin_password_hash" {
  description = "Pre-computed bcrypt hash of the ArgoCD admin password. When set, Infisical is not consulted."
  type        = string
  # Dead as of the switch to OIDC-via-Dex login (argocd.tf sets admin.enabled:
  # "false" and comments out the Infisical fetch) -- nothing consumes this value
  # anymore. Default restored so a plain `-var-file` apply (CI included) doesn't
  # fail on "no value for required variable" for a variable no resource reads.
  default = ""
}

# ── Cross-root state reads (Scaleway state buckets, see 00-foundation/scaleway) ──

variable "backup_scaleway_state_bucket" {
  description = "Scaleway bucket holding 03-storage/scaleway's remote state."
  type        = string
}

variable "backup_scaleway_state_key" {
  description = "Object key for 03-storage/scaleway's state within backup_scaleway_state_bucket."
  type        = string
}

variable "openbao_unseal_aws_state_bucket" {
  description = "Scaleway bucket holding 02-encryption/aws's remote state."
  type        = string
}

variable "openbao_unseal_aws_state_key" {
  description = "Object key for 02-encryption/aws's state within openbao_unseal_aws_state_bucket."
  type        = string
}

variable "dns_scaleway_state_bucket" {
  description = "Scaleway bucket holding 01-iam/workload/scaleway's remote state."
  type        = string
}

variable "dns_scaleway_state_key" {
  description = "Object key for 01-iam/workload/scaleway's state within dns_scaleway_state_bucket."
  type        = string
}

