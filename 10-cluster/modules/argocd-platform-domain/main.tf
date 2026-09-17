# One ArgoCD Application, rendered via the upstream argocd-apps chart -- the
# repeated shape every single platform-apps domain in
# 10-cluster/kind/argocd.tf and 10-cluster/scaleway/argocd.tf shared
# verbatim before infra#113 (same chart/version/timeout, same
# finalizers/project/destination/syncPolicy, only the Application name, its
# source valueFiles/parameters, and its depends_on wiring actually varied).
#
# Deliberately does NOT also own a module.wait-argocd-apps-healthy gate --
# some domains need one, some don't, and among the ones that do, downstream
# consumers vary between a SOFT create/destroy-order dependency on this
# Application existing (depends_on = [module.<this>]) and a HARD dependency
# on it actually being Synced+Healthy (a separate module.wait_<x>_healthy
# call). Folding the wait Job in here would make every downstream depends_on
# on this module implicitly hard (Terraform's module-level depends_on waits
# for every resource inside), silently losing that distinction -- see
# 10-cluster/scaleway/platform-apps/README.md's "networking_controllers_apps"
# depends_on comment for a real example of a soft dependency that must NOT
# become a hard one. Each root's own argocd.tf still instantiates
# module.wait-argocd-apps-healthy directly wherever a hard gate is actually
# needed, same as before -- see that module's own README for why ArgoCD has
# no native way to express this itself.
locals {
  helm_block = merge(
    length(var.value_files) > 0 ? { valueFiles = var.value_files } : {},
    length(var.parameters) > 0 ? { parameters = var.parameters } : {},
  )

  application_spec = {
    namespace  = var.namespace
    finalizers = ["resources-finalizer.argocd.argoproj.io"]
    project    = "default"
    source = merge(
      {
        repoURL        = var.source_repo
        targetRevision = var.target_revision
        path           = var.source_path
      },
      length(local.helm_block) > 0 ? { helm = local.helm_block } : {},
    )
    destination = {
      server    = "https://kubernetes.default.svc"
      namespace = var.namespace
    }
    syncPolicy = {
      retry = {
        limit = 10
      }
      automated = {
        prune    = true
        selfHeal = true
      }
      syncOptions = ["CreateNamespace=true"]
    }
  }
}

resource "helm_release" "this" {
  name      = "argocd-${var.name}"
  namespace = var.namespace

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.4"

  # Applies to both install AND uninstall -- see
  # 10-cluster/scaleway/argocd.tf's original comment on this same value for
  # why (ArgoCD's resources-finalizer.argocd.argoproj.io makes a Helm
  # uninstall wait for the whole child-Application tree to cascade-delete
  # first, confirmed live to exceed 5 minutes).
  timeout = var.timeout

  values = [yamlencode({ applications = { (var.name) = local.application_spec } })]
}
