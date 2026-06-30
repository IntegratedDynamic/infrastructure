data "infisical_secrets" "this" {
  count        = var.argocd_admin_password_hash == "" ? 1 : 0
  env_slug     = "local"
  workspace_id = "7ecb6ed4-058a-46cd-ac9f-7e792469cf0f" // project ID
  folder_path  = "/"
}

locals {
  argocd_password_hash = var.argocd_admin_password_hash != "" ? var.argocd_admin_password_hash : data.infisical_secrets.this[0].secrets["ArgoCD_admin_encrypted"].value
}

resource "kubernetes_namespace" "openbao" {
  metadata {
    name = "openbao"
  }
}

resource "kubernetes_secret" "scaleway_s3_credentials" {
  metadata {
    name      = "scaleway-s3-credentials"
    namespace = kubernetes_namespace.openbao.metadata[0].name
  }

  data = {
    bucket     = "backup-dev-id"
    AWS_ACCESS_KEY_ID = "SCW8FGA70P4HY3A120KV"
    AWS_SECRET_ACCESS_KEY = var.scaleway_s3_secret_key
  }
}

# AWS credentials OpenBao reads at startup for KMS auto-unseal (seal "awskms").
# Sourced here — outside OpenBao — by necessity: OpenBao can't supply the very
# creds it needs to unseal itself (chicken-and-egg). Values come from the
# 03-backup/scaleway kms.tf outputs, fed via the gitignored *.auto.tfvars.
# Key names (access_key/secret_key) mirror scaleway-s3-credentials so the
# OpenBao chart's extraSecretEnvironmentVars mapping stays uniform.
resource "kubernetes_secret" "openbao_unseal_aws" {
  metadata {
    name      = "openbao-unseal-aws"
    namespace = kubernetes_namespace.openbao.metadata[0].name
  }

  data = {
    AWS_ACCESS_KEY_ID = var.openbao_unseal_aws_access_key_id
    AWS_SECRET_ACCESS_KEY = var.openbao_unseal_aws_secret_access_key
  }
}

resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "9.4.17"

  set_sensitive = [{
    name = "configs.secret.argocdServerAdminPassword"
    # ArgoCD require a `bcrypt()` hashed password here. But `bcrypt` generate a new hash at each execution
    # So instead, we store the hash directly, so terraform is not confused anymore by fake changes
    value = local.argocd_password_hash
  }]

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
            value: local
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
