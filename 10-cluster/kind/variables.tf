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
# own head SHA so a PR touching 10-cluster/platform-apps actually
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
# Not `sensitive` on purpose: these only reach kubernetes_secret data, which the
# provider already hides, and marking them made OpenTofu plan an update of every
# such Secret without any value changing. Keep them out of anything else.
variable "core_storage" {
  description = "Outputs of the core's 03-storage/scaleway (buckets and their workload keys), passed by live/clusters/core.hcl."
  type = object({
    bucket_name         = string
    workload_access_key = string
    workload_secret_key = string
  })
}

variable "core_unseal" {
  description = "Outputs of the core's 02-encryption/aws (the IAM key OpenBao auto-unseals with), passed by live/clusters/core.hcl."
  type = object({
    openbao_unseal_access_key_id     = string
    openbao_unseal_secret_access_key = string
  })
}

# infra#113: the whole platform-apps DAG this tier validates, as data -- see
# modules/platform-apps-dag/variables.tf's own var.domains for the full
# schema (kept in sync by hand, Terraform has no cross-root shared-type
# import). Populated by env/10-cluster-kind-kind.tfvars; this root's
# own argocd.tf only merges in the handful of Secret dependencies that live
# in main.tf (can't be expressed as tfvars data -- see that file's own
# comment) before calling the module.
variable "domains" {
  type = map(object({
    source        = optional(string, "infra")
    value_files   = optional(list(string), [])
    parameters    = optional(list(object({ name = string, value = string })), [])
    needs_crds    = optional(bool, false)
    needs_secrets = optional(bool, false)
    needs_backups = optional(bool, false)
    # Keep in sync with modules/platform-apps-dag/variables.tf: an attribute
    # missing from this object type is silently DROPPED on conversion (no
    # error), turning its needs_* gate into a no-op. That is exactly how
    # needs_networking_controllers/needs_grafana were inert from
    # d2cbdbc (2026-09-17) until this fix.
    needs_networking_controllers = optional(bool, false)
    needs_grafana                = optional(bool, false)
    needs_keda                   = optional(bool, false)
    depends_on_ids               = optional(list(string), [])
    namespace                    = optional(string, "argocd")
  }))
}
