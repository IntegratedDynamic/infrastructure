# data "infisical_secrets" "this" {
#   env_slug     = "staging"
#   workspace_id = "7ecb6ed4-058a-46cd-ac9f-7e792469cf0f" // project ID
#   folder_path  = "/"
# }

resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "9.4.17"

  # Fail fast (under the 5m default) if ArgoCD doesn't come up. Transient blips
  # (e.g. quay.io 502s) are absorbed by retrying the apply (see mise scaleway-up).
  timeout = 240

  depends_on = [scaleway_k8s_pool.default]

  values = [<<EOF
configs:
  params:
    server.insecure: true

  cm:
    url: https://argocd.scalepack.fr

    # Local admin login is redundant now that OIDC via Dex is working —
    # one login path, no separate password to rotate/leak. To bring back
    # a break-glass fallback: set this back to "true" and restore the
    # set_sensitive block (removed in this commit — see git history) that
    # sets configs.secret.argocdServerAdminPassword from
    # var.argocd_admin_password_hash.
    admin.enabled: "false"

    # Native OIDC against our own shared Dex (platform/scaleway/dex.yml in
    # the gitops repo, staticClients.argocd) instead of the chart's built-in
    # Dex (disabled below) — one Dex instance for the whole platform, one
    # place the GitHub org/team restriction is defined.
    oidc.config: |
      name: Dex
      issuer: https://auth.scalepack.fr
      clientID: argocd
      # Resolved from the argocd-oidc-client-secret Secret (gitops repo:
      # apps/argocd-config), not the default argocd-secret — that secret
      # carries the app.kubernetes.io/part-of: argocd label ArgoCD requires
      # for custom secret references.
      clientSecret: $argocd-oidc-client-secret:oidc.clientSecret
      requestedScopes:
        - openid
        - profile
        - email
        - groups

  rbac:
    policy.csv: |
      g, IntegratedDynamic:Admin, role:admin
    policy.default: role:readonly

# The chart's own embedded Dex is redundant now that ArgoCD talks OIDC
# directly to our shared Dex — turned off rather than run two.
dex:
  enabled: false

controller:
  replicas: 1

repoServer:
  replicas: 1
EOF
  ]
}

resource "helm_release" "argocd_apps" {
  name      = "argocd-apps"
  namespace = "argocd"

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.4"

  depends_on = [helm_release.argocd]

  values = [<<EOF
applications:
  bootstrap:
    namespace: argocd
    project: default

    source:
      repoURL: https://github.com/IntegratedDynamic/gitops.git
      targetRevision: ${var.gitops_revision}
      path: bootstrap
      helm:
        parameters:
          - name: env
            value: scaleway
          - name: revision
            value: ${var.gitops_revision}

    destination:
      server: https://kubernetes.default.svc
      namespace: argocd

    syncPolicy:
      automated:
        prune: true
        selfHeal: true
      syncOptions:
        - CreateNamespace=true
EOF
  ]
}
