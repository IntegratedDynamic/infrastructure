data "infisical_secrets" "this" {
  env_slug     = "local"
  workspace_id = "7ecb6ed4-058a-46cd-ac9f-7e792469cf0f" // project ID
  folder_path  = "/"
}

resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "9.4.17"

  set_sensitive {
    name  = "configs.secret.argocdServerAdminPassword"
    # ArgoCD require a `bcrypt()` hashed password here. But `bcrypt` generate a new hash at each execution
    # So instead, we store the hash directly, so terraform is not confused anymore by fake changes
    value = data.infisical_secrets.this.secrets["ArgoCD_admin_encrypted"].value
  }

  values = [<<EOF
# server:
#   service:
#     type: LoadBalancer

configs:
  params:
    server.insecure: true

controller:
  replicas: 1

repoServer:
  replicas: 1
EOF
  ]
}
resource "helm_release" "argocd_apps" {
  name       = "argocd-apps"
  namespace  = "argocd"

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
      targetRevision: main
      path: bootstrap

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
