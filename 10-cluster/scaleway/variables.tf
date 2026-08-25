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

variable "gitops_revision" {
  type    = string
  default = "main"
}

# Revision of THIS repo (infrastructure) ArgoCD's secrets-apps/monitoring-apps/
# backups-apps Applications pull platform-apps/ from — see argocd.tf's
# argocd_platform_apps helm_release. Same "override on your own branch to
# test end-to-end, never merge that change" DevX trick as gitops_revision
# above; MUST stay "main" on origin/main.
variable "infra_revision" {
  type    = string
  default = "main"
}

variable "update_kubeconfig" {
  type        = bool
  default     = false
  description = "Set to true when using locally to automatically update you ~/.kube/config. Require `kubectl` and `scw` installed & configured."
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

