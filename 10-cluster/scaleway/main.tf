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

# Replaces Scaleway's auto-managed "Kapsule default security group" on the
# node pool below — that group ships with ZERO inbound rules and a
# default-drop policy, meaning nothing reaches a node's public IP directly
# at all. Confirmed live 2026-08-09 investigating why the WireGuard
# NodePort (gitops repo's services/platform/wireguard) never received a
# single packet despite correct Kubernetes-level config (Service,
# NetworkPolicy) — this sits below Kubernetes entirely, at the instance
# level, so nothing in-cluster could have fixed it.
#
# Same default-drop inbound posture as Scaleway's own default, plus
# exactly one explicit allow. 80/443 keep working unaffected either way —
# that traffic arrives via the LB over Scaleway's internal path, never
# subject to this instance-level firewall.
#
# COUPLING: each port below must match its gitops chart's
# server.nodePort exactly — same "two systems kept in sync by convention"
# pattern already used for 05-secrets/openbao/managed's secrets_sync_github
# vs. that repo's apps/secrets-sync/values.yaml. Changing one without the
# other silently breaks the tunnel again, the same way this whole
# investigation started.
resource "scaleway_instance_security_group" "cluster_nodes" {
  name        = "${var.cluster_name}-nodes"
  description = "Explicit inbound allowlist for cluster nodes' public IPs — see main.tf's comment on this resource."

  inbound_default_policy  = "drop"
  outbound_default_policy = "accept"
  enable_default_security = true

  inbound_rule {
    action   = "accept"
    protocol = "UDP"
    port     = 30820 # gitops: services/platform/wireguard-site-to-site/config/values.yaml server.nodePort
  }

  inbound_rule {
    action   = "accept"
    protocol = "UDP"
    port     = 30821 # gitops: services/platform/wireguard-exit/config/values.yaml server.nodePort
  }
}

resource "scaleway_k8s_pool" "default" {
  cluster_id        = scaleway_k8s_cluster.this.id
  name              = "default"
  node_type         = "DEV1-M"
  security_group_id = scaleway_instance_security_group.cluster_nodes.id
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
# is parametrized via variables.tf + env/, visible there instead of buried
# here.
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
# scoped workload identity. Same remote state key 05-secrets/openbao/managed
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
  depends_on = [scaleway_k8s_pool.default]
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
