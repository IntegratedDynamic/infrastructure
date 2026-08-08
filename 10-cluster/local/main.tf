data "infisical_secrets" "this" {
  count        = var.argocd_admin_password_hash == "" ? 1 : 0
  env_slug     = "local"
  workspace_id = "7ecb6ed4-058a-46cd-ac9f-7e792469cf0f" // project ID
  folder_path  = "/"
}

locals {
  argocd_password_hash = var.argocd_admin_password_hash != "" ? var.argocd_admin_password_hash : data.infisical_secrets.this[0].secrets["ArgoCD_admin_encrypted"].value
}

# scaleway-s3-credentials source: 03-storage/scaleway's "backup" bucket + its
# scoped workload identity. Same remote state key 05-secrets/openbao/managed
# reads as its own `backup_scaleway` data source.
data "terraform_remote_state" "backup_scaleway" {
  backend = "s3"
  config = {
    bucket = "id-terraform-state20260612164136440800000001"
    region = "eu-west-3"
    key    = "backup/scaleway/03-backup-dev-bucket/terraform.tfstate"
  }
}

# AWS credentials OpenBao reads at startup for KMS auto-unseal (seal "awskms")
# — source: 02-encryption/aws's KMS key + dedicated IAM user.
data "terraform_remote_state" "openbao_unseal_aws" {
  backend = "s3"
  config = {
    bucket = "id-terraform-state20260612164136440800000001"
    region = "eu-west-3"
    key    = "openbao-unseal/aws/03-backup-dev-bucket/terraform.tfstate"
  }
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
    bucket                 = data.terraform_remote_state.backup_scaleway.outputs.bucket_name
    AWS_ACCESS_KEY_ID      = data.terraform_remote_state.backup_scaleway.outputs.workload_access_key
    AWS_SECRET_ACCESS_KEY  = data.terraform_remote_state.backup_scaleway.outputs.workload_secret_key
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
    AWS_ACCESS_KEY_ID = data.terraform_remote_state.openbao_unseal_aws.outputs.openbao_unseal_access_key_id
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
