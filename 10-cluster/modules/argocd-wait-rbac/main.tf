# Shared RBAC for every module.wait-argocd-apps-healthy instance in a root
# (10-cluster/kind, 10-cluster/scaleway) -- one ServiceAccount/Role/
# RoleBinding per root, reused by every wait Job it creates, instead of
# minting a fresh one per domain. Scoped to exactly what those Jobs need
# (read-only on Applications in the argocd namespace), nothing broader.
#
# Extracted (infra#113) out of what used to be identical copy-pasted
# resources in 10-cluster/kind/argocd.tf and 10-cluster/scaleway/argocd.tf --
# see 10-cluster/scaleway/argocd.tf's original comment on these resources
# for the "why an explicit depends_on on the ArgoCD release" reasoning
# (confirmed live 2026-08-25: without it, nothing ordered these after
# anything more than the cluster/pool itself, racing DNS resolution on the
# cluster's own API hostname). Callers pass that dependency via this
# module's own `depends_on` meta-argument.
resource "kubernetes_service_account" "wait_platform_apps" {
  metadata {
    name      = "wait-platform-apps-healthy"
    namespace = "argocd"
  }
}

resource "kubernetes_role" "wait_platform_apps" {
  metadata {
    name      = "wait-platform-apps-healthy"
    namespace = "argocd"
  }

  rule {
    api_groups = ["argoproj.io"]
    resources  = ["applications"]
    verbs      = ["get", "list"]
  }
}

resource "kubernetes_role_binding" "wait_platform_apps" {
  metadata {
    name      = "wait-platform-apps-healthy"
    namespace = "argocd"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.wait_platform_apps.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.wait_platform_apps.metadata[0].name
    namespace = "argocd"
  }
}
