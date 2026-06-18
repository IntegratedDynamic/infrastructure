data "infisical_secrets" "this" {
  env_slug     = "staging"
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

  # Fail fast (under the 5m default) if ArgoCD doesn't come up. Transient blips
  # (e.g. quay.io 502s) are absorbed by retrying the apply (see mise scaleway-up).
  timeout = 240

  depends_on = [scaleway_k8s_pool.default]

  set_sensitive = [{
    name = "configs.secret.argocdServerAdminPassword"
    # ArgoCD expects a bcrypt() hash here. bcrypt() would regenerate on every
    # run, so we store the hash directly in Infisical to avoid spurious diffs.
    value = data.infisical_secrets.this.secrets["ArgoCD_admin_encrypted"].value
  }]

  values = [<<EOF
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
