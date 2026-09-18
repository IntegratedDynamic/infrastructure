variable "domains" {
  description = <<-EOT
    The whole platform-apps DAG for this root, as data -- one entry per
    ArgoCD Application. The only thing that should differ between
    10-cluster/kind, 10-cluster/scaleway, or a future cluster variant is
    which entries exist here and how they're configured (normally sourced
    straight from env/*.tfvars), not hand-written Terraform.

    This platform's real cross-domain DAG (confirmed against every
    existing dependency across both roots) reduces to SIX independent,
    individually-named gates -- see main.tf's own header comment for why a
    fully generic named-DAG isn't expressible here at all (a real OpenTofu
    limitation, not a design choice) and why six fixed gates is not a
    watered-down substitute for one: it's an EXACT match for this
    platform's actual shape (every real edge across both roots' domains,
    zero coarsening), with FULL parallelism preserved for anything that
    doesn't need a gate, and NO domain ever waits on a gate it doesn't
    actually need (unlike a generic topological-level scheme, which would
    force everything in one level to wait for everything in the level
    below it, whether it needed to or not).

      source          "infra" (default -- this repo's own
                      var.infra_source_repo/var.infra_source_path/
                      var.infra_revision) or "gitops" (the gitops repo's
                      own var.gitops_source_repo/var.gitops_source_path/
                      var.gitops_revision). Only "bootstrap" uses "gitops"
                      today.
      value_files     Helm valueFiles for the rendered Application,
                      relative to the resolved source_path.
      parameters      Extra Helm parameters beyond the "revision" one
                      every domain gets automatically (see main.tf).
      needs_crds                     This domain's Application isn't
                                     created until the "crds-apps" domain
                                     reports Synced+Healthy -- for a chart
                                     that assumes a CRD it doesn't itself
                                     own is already Established.
      needs_secrets                  Same, gated on "secrets-apps" -- for
                                     a chart consuming an OpenBao/ESO-
                                     delivered ExternalSecret.
      needs_backups                  Same, gated on "backups-apps" -- for
                                     a chart consuming one of Velero's
                                     restore hooks (cert-restore/
                                     grafana-restore).
      needs_dex                      Same, gated on "dex-apps" -- for a
                                     chart (argo-workflows-apps) that
                                     eager-dials Dex's OIDC issuer at pod
                                     startup and crash-loops if it isn't
                                     reachable yet.
      needs_networking_controllers   Same, gated on
                                     "networking-controllers-apps" -- for
                                     a chart (networking-resources-apps)
                                     whose ClusterIssuers fail outright at
                                     the API level if cert-manager's
                                     webhook isn't registered and serving
                                     yet.
      needs_grafana                  Same, gated on "grafana-apps" -- for
                                     crossplane-apps, whose Workspaces
                                     shouldn't burn reconcile attempts
                                     before Grafana's own provider target
                                     is reachable.
      depends_on_ids                 Opaque values (e.g. a
                                     kubernetes_secret.foo.id from the
                                     calling root's own main.tf) this
                                     Application must wait on. The only
                                     escape hatch for a genuinely
                                     root-specific dependency -- callers
                                     build this list in their own locals,
                                     never by hand in env/*.tfvars (a
                                     literal string there couldn't
                                     reference a real resource).
      namespace                      Defaults to "argocd" -- every
                                     existing domain.

    Every needs_* flag is a no-op (silently ignored, not an error) if
    var.domains has no entry for the gate's own domain -- a root that
    genuinely lacks one of these six domains simply never creates that
    gate, and nothing can wait on it.
  EOT
  type = map(object({
    source                       = optional(string, "infra")
    value_files                  = optional(list(string), [])
    parameters                   = optional(list(object({ name = string, value = string })), [])
    needs_crds                   = optional(bool, false)
    needs_secrets                = optional(bool, false)
    needs_backups                = optional(bool, false)
    needs_dex                    = optional(bool, false)
    needs_networking_controllers = optional(bool, false)
    needs_grafana                = optional(bool, false)
    depends_on_ids               = optional(list(string), [])
    namespace                    = optional(string, "argocd")
  }))
}

variable "infra_source_repo" {
  description = "Git URL this repo (infrastructure) is cloned from, for every domain with source = \"infra\"."
  type        = string
  default     = "https://github.com/IntegratedDynamic/infrastructure.git"
}

variable "infra_source_path" {
  description = "Path within var.infra_source_repo the shared platform-apps chart lives at, for every domain with source = \"infra\"."
  type        = string
  default     = "10-cluster/platform-apps"
}

variable "infra_revision" {
  description = "Already-resolved targetRevision for every domain with source = \"infra\" -- callers own their own fallback logic (e.g. 10-cluster/scaleway's git-existence probe vs. 10-cluster/kind's plain passthrough) before this value ever reaches the module."
  type        = string
}

variable "gitops_source_repo" {
  description = "Git URL the gitops repo is cloned from, for every domain with source = \"gitops\"."
  type        = string
  default     = "https://github.com/IntegratedDynamic/gitops.git"
}

variable "gitops_source_path" {
  description = "Path within var.gitops_source_repo, for every domain with source = \"gitops\"."
  type        = string
  default     = "bootstrap"
}

variable "gitops_revision" {
  description = "Already-resolved targetRevision for every domain with source = \"gitops\", AND the value auto-injected as every domain's own \"revision\" Helm parameter regardless of its own source -- every domain, including \"infra\"-sourced ones, ultimately renders a chart whose OWN child Applications should track the gitops repo at this revision."
  type        = string
}

variable "wait_all_domains_healthy" {
  description = "Whether to create the final wait-all-domains-healthy Job, gating on every domain in var.domains reporting Synced+Healthy."
  type        = bool
  default     = true
}
