# Branch of the gitops repo bootstrap's `demo` app tracks -- same
# "override on your own branch, test end-to-end, never merge that change"
# convention as 10-cluster/scaleway's var.gitops_revision, without that
# root's git-existence-probe machinery (not needed here: the kind tier only
# ever runs from a real PR's own checkout, so the ref it's told to use
# always exists).
variable "gitops_revision" {
  type    = string
  default = "main"
}

# Revision of THIS repo (infrastructure) the platform-apps Applications
# below pull their chart from. The kind CI workflow sets this to the PR's
# own head SHA so a PR touching 10-cluster/scaleway/platform-apps actually
# gets validated against ITS OWN changes, not main -- the entire point of
# this tier. See argocd.tf's local.platform_apps_source_repo.
variable "infra_revision" {
  type    = string
  default = "main"
}

# ── Cross-root state reads (Scaleway state buckets) ─────────────────────────
#
# Same two remote-state reads 10-cluster/scaleway/main.tf already does, same
# variable names/defaults -- this tier restores OpenBao's REAL production
# raft snapshot (see main.tf's own header comment for why: seal "awskms"
# wraps the barrier key using the real production KMS key, so a target
# instance can only unseal a restored snapshot if it runs the SAME seal
# config against the SAME key -- there is no lower-privilege way to make a
# real snapshot restorable). Needs real Scaleway state-bucket credentials in
# CI (AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY, same as every other Scaleway-
# hosted root's cross-root read -- see this repo's CLAUDE.md Setup section).
variable "backup_scaleway_state_bucket" {
  description = "Scaleway bucket holding 03-storage/scaleway's remote state."
  type        = string
  default     = "id-terraform-state-03-storage-scaleway"
}

variable "backup_scaleway_state_key" {
  description = "Object key for 03-storage/scaleway's state within backup_scaleway_state_bucket."
  type        = string
  default     = "03-storage/scaleway/03-storage-scaleway-dev/terraform.tfstate"
}

variable "openbao_unseal_aws_state_bucket" {
  description = "Scaleway bucket holding 02-encryption/aws's remote state."
  type        = string
  default     = "id-terraform-state-02-encryption-aws"
}

variable "openbao_unseal_aws_state_key" {
  description = "Object key for 02-encryption/aws's state within openbao_unseal_aws_state_bucket."
  type        = string
  default     = "02-encryption/aws/02-encryption-aws-dev/terraform.tfstate"
}

# infra#113: the whole platform-apps DAG this tier validates, as data -- see
# modules/platform-apps-dag/variables.tf's own var.domains for the full
# schema (kept in sync by hand, Terraform has no cross-root shared-type
# import). Populated by env/10-cluster-kind-github-pr.tfvars; this root's
# own argocd.tf only merges in the handful of Secret dependencies that live
# in main.tf (can't be expressed as tfvars data -- see that file's own
# comment) before calling the module.
variable "domains" {
  type = map(object({
    source         = optional(string, "infra")
    value_files    = optional(list(string), [])
    parameters     = optional(list(object({ name = string, value = string })), [])
    needs_crds     = optional(bool, false)
    needs_secrets  = optional(bool, false)
    needs_backups  = optional(bool, false)
    depends_on_ids = optional(list(string), [])
    namespace      = optional(string, "argocd")
  }))
}
