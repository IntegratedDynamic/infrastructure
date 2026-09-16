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

# Threaded into networking_resources_apps' Application (argocd.tf) as the
# `hostSuffix` Helm parameter, which every `*-gateway` chart appends to its
# own hostname (gitops repo). Deliberately generic, not "pr_number" -- in
# practice the ephemeral workflow (scaleway-ephemeral.yml) always sets this
# to "pr-<number>", but nothing here cares what the string actually is,
# only that it's unique per concurrent ephemeral cluster. Empty by default
# (main's own workspace): zero behavior change, every hostname stays
# exactly what it is today (e.g. "argocd.scalepack.fr"). When set, every
# hostname gets "-${var.env_suffix}" appended (e.g.
# "argocd-pr-123.scalepack.fr") -- a flat, single-DNS-label suffix, not a
# nested subdomain, so it stays covered by gateway-config's existing
# *.scalepack.fr wildcard cert with zero change to that chart.
# nullable = false: argocd.tf's local.host_suffix only tests `!= ""`, which
# would silently treat an explicit `env_suffix = null` override as non-empty
# (null != "" is true in Terraform) and then crash deep in a string
# interpolation ("-${null}" errors: "Cannot include a null value in a string
# template") instead of failing clearly, or degrading gracefully, at the
# boundary. Confirmed live (isolated repro): with both nullable = false and
# this default set, OpenTofu silently substitutes the default ("") for an
# explicit null override rather than erroring -- so local.host_suffix's
# existing `!= ""` check is already correct and sufficient, because null can
# no longer reach it as null at all.
variable "env_suffix" {
  description = "Pseudo-random unique suffix identifying this cluster's environment (e.g. \"pr-123\"). Empty for the main/dev workspace. When set, every platform hostname (ArgoCD, Grafana, OpenBao, ...) gets \"-<env_suffix>\" appended so this cluster's hostnames never collide with another concurrently-running one."
  type        = string
  default     = ""
  nullable    = false
}

# Controls whether module.wait_all_domains_healthy (argocd.tf, moved to the
# very end of this file's resource graph -- see that module's own comment)
# actually runs. Confirmed live 2026-09-16 (ephemeral cluster pr-109):
# crossplane-apps' own tofu-apply-in-a-Workspace loop (11-secrets/openbao
# /managed, 12-monitoring/grafana/{bootstrap,managed}) takes far longer to
# first-converge than every other domain -- fine to wait out on main's own
# workspace (a genuine "the whole platform, including the slow stuff, is
# done" confirmation), but not worth paying for on every ephemeral-cluster
# test run, where the point is usually just "did the core platform + gitops
# tree come up", not crossplane specifically. Default true: main's own
# workspace keeps today's behavior unchanged; the ephemeral workflow
# (scaleway-ephemeral.yml) sets this to false in its generated tfvars.
variable "wait_all_domains_healthy" {
  description = "Whether to run the final module.wait_all_domains_healthy gate (waits for every platform domain, crossplane-apps included, to be Synced+Healthy) at the end of apply. true for main's own workspace; the ephemeral workflow sets this false to skip crossplane's slow first-convergence."
  type        = bool
  default     = true
}

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

