data "infisical_secrets" "this" {
  count        = var.argocd_admin_password_hash == "" ? 1 : 0
  env_slug     = "local"
  workspace_id = "7ecb6ed4-058a-46cd-ac9f-7e792469cf0f" // project ID
  folder_path  = "/"
}

locals {
  argocd_password_hash = var.argocd_admin_password_hash != "" ? var.argocd_admin_password_hash : data.infisical_secrets.this[0].secrets["ArgoCD_admin_encrypted"].value
}

# Credentials for the cross-root Scaleway state reads below: read straight
# from the scw CLI's own config (the same credentials `provider "scaleway"
# {}` already uses implicitly everywhere else) instead of requiring
# AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY set ambiently. Terraform's s3
# backend/data source has no notion of the scw CLI's own config format —
# this bridges the two credential systems automatically, so any admin who
# already has `scw` configured (a repo-wide prerequisite already) needs zero
# extra setup.
data "external" "scw_credentials" {
  program = ["sh", "-c", "jq -n --arg ak \"$(scw config get access-key)\" --arg sk \"$(scw config get secret-key)\" '{access_key:$ak, secret_key:$sk}'"]
}

# Shared technical attributes for every cross-root Scaleway state read below
# — not "config" in the meaningful sense (they never vary), just the
# Scaleway S3-compatible endpoint mechanics repeated per data source
# otherwise. The actual config — which bucket/key, i.e. which root's state —
# is parametrized via variables.tf, visible there instead of buried here.
locals {
  scaleway_state_backend = {
    region                      = "fr-par"
    access_key                  = data.external.scw_credentials.result.access_key
    secret_key                  = data.external.scw_credentials.result.secret_key
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
    use_path_style              = true
    endpoints = {
      s3 = "https://s3.fr-par.scw.cloud"
    }
  }
}

# scaleway-s3-credentials source: 03-storage/scaleway's "backup" bucket + its
# scoped workload identity. Same remote state key 11-secrets/openbao/managed
# reads as its own `backup_scaleway` data source.
data "terraform_remote_state" "backup_scaleway" {
  backend = "s3"
  config = merge(local.scaleway_state_backend, {
    bucket = var.backup_scaleway_state_bucket
    key    = var.backup_scaleway_state_key
  })
}

# AWS credentials OpenBao reads at startup for KMS auto-unseal (seal "awskms")
# — source: 02-encryption/aws's KMS key + dedicated IAM user.
data "terraform_remote_state" "openbao_unseal_aws" {
  backend = "s3"
  config = merge(local.scaleway_state_backend, {
    bucket = var.openbao_unseal_aws_state_bucket
    key    = var.openbao_unseal_aws_state_key
  })
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
    bucket                = data.terraform_remote_state.backup_scaleway.outputs.bucket_name
    AWS_ACCESS_KEY_ID     = data.terraform_remote_state.backup_scaleway.outputs.workload_access_key
    AWS_SECRET_ACCESS_KEY = data.terraform_remote_state.backup_scaleway.outputs.workload_secret_key
  }
}

# AWS credentials OpenBao reads at startup for KMS auto-unseal (seal "awskms").
# Sourced here — outside OpenBao — by necessity: OpenBao can't supply the very
# creds it needs to unseal itself (chicken-and-egg). Key names (access_key/
# secret_key) mirror scaleway-s3-credentials so the OpenBao chart's
# extraSecretEnvironmentVars mapping stays uniform.
resource "kubernetes_secret" "openbao_unseal_aws" {
  metadata {
    name      = "openbao-unseal-aws"
    namespace = kubernetes_namespace.openbao.metadata[0].name
  }

  data = {
    AWS_ACCESS_KEY_ID     = data.terraform_remote_state.openbao_unseal_aws.outputs.openbao_unseal_access_key_id
    AWS_SECRET_ACCESS_KEY = data.terraform_remote_state.openbao_unseal_aws.outputs.openbao_unseal_secret_access_key
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
