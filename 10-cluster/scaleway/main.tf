resource "scaleway_vpc_private_network" "cluster" {}

resource "scaleway_k8s_cluster" "this" {
  name    = var.cluster_name
  version = "1.35"

  auto_upgrade {
    enable                        = true
    maintenance_window_start_hour = 2
    maintenance_window_day        = "any"
  }
  cni                = "cilium"
  type               = "kapsule"
  private_network_id = scaleway_vpc_private_network.cluster.id

  delete_additional_resources = true

  tags = ["homelab", "terraform"]
}

resource "scaleway_k8s_pool" "default" {
  cluster_id  = scaleway_k8s_cluster.this.id
  name        = "default"
  node_type   = "DEV1-M"
  # Put whatever number is required to avoid node pressure signals during startup: https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/
  # Node pressure during startup can end-up with unexcepted race conditions.
  size        = var.node_count
  min_size    = 1
  max_size    = 3
  autoscaling = true
  autohealing = true

  lifecycle {
    create_before_destroy = true
  }
}

# ------------------------------------------------------------
# Optional ressource, mainly for local debugging capabilities.

locals {
  cluster_uuid = split("/", scaleway_k8s_cluster.this.id)[1]
}

resource "null_resource" "update_kubeconfig" {
  count = var.update_kubeconfig ? 1 : 0

  triggers = {
    cluster_id   = scaleway_k8s_cluster.this.id
    context_name = var.cluster_name
  }

  depends_on = [scaleway_k8s_pool.default]

  provisioner "local-exec" {
    command = <<-EOT
      scw k8s kubeconfig install ${local.cluster_uuid}
      # Override any pre-existing context with the target name, then rename.
      kubectl config delete-context "${var.cluster_name}" 2>/dev/null || true
      kubectl config rename-context "${scaleway_k8s_cluster.this.name}-${local.cluster_uuid}" "${var.cluster_name}"
    EOT
  }
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
  depends_on = [scaleway_k8s_pool.default]
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
