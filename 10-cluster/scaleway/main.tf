resource "scaleway_vpc_private_network" "cluster" {}

# Scaleway rejects a new cluster sharing a name with one still in a
# terminal-but-not-gone state — confirmed live 2026-08-20: a previous
# "scaleway-homelab" cluster got wedged in `deleting` for 9+ hours (an
# orphaned instance server still holding 2 block volumes, itself stuck
# `archived`, blocked Scaleway's own cascade cleanup) and blocked recreation
# under the same name the whole time. random_id is stable across applies
# (only regenerates on explicit -replace), so this doesn't rename the
# cluster on every apply — it just guarantees a fresh name if a future
# delete gets wedged again. var.cluster_name stays the stable local kubectl
# context name (null_resource.update_kubeconfig below), independent of the
# actual Scaleway resource name.
resource "random_id" "cluster_suffix" {
  byte_length = 2
}

locals {
  cluster_resource_name = "${var.cluster_name}-${random_id.cluster_suffix.hex}"
}

resource "scaleway_k8s_cluster" "this" {
  name    = local.cluster_resource_name
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
# pattern already used for 11-secrets/openbao/managed's secrets_sync_github
# vs. that repo's apps/secrets-sync/values.yaml. Changing one without the
# other silently breaks the tunnel again, the same way this whole
# investigation started.
resource "scaleway_instance_security_group" "cluster_nodes" {
  name        = "${local.cluster_resource_name}-nodes"
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
  cluster_id = scaleway_k8s_cluster.this.id
  name       = "default"
  # Bumped DEV1-M (3 vCPU/4GB) -> DEV1-L (4 vCPU/8GB) 2026-08-20: confirmed
  # live that DEV1-M was routinely hitting MemoryPressure/evicting pods
  # during a full ArgoCD tree sync -- the more waves ArgoCD advances
  # through, the more DaemonSets (Cilium, node-exporter, Alloy, ...) run a
  # pod on every node, compounding the same small-node pressure. Doubling
  # RAM at roughly double the price (~15€ -> ~31€/mo/node) is the
  # proportionate fix; create_before_destroy below means this replaces the
  # pool without a bare window.
  node_type         = "DEV1-L"
  security_group_id = scaleway_instance_security_group.cluster_nodes.id
  # Put whatever number is required to avoid node pressure signals during startup: https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/
  # Node pressure during startup can end-up with unexcepted race conditions.
  size        = var.node_count
  min_size    = 1
  max_size    = 5
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


# Credentials for the cross-root Scaleway state reads below. Two execution
# contexts apply this root: an admin's machine (scw CLI configured) and
# .github/workflows/scaleway.yml's CI job, which already sets
# SCW_ACCESS_KEY/SCW_SECRET_KEY as job env (for `provider "scaleway" {}`)
# but had no way to hand them to this data source — env vars now win when
# set, falling back to `scw config get` for the admin path. Same fix as
# 11-secrets/openbao/managed/main.tf's identical comment (that root's own
# CronWorkflow prompted finding this one too — see infra PR #66).
data "external" "scw_credentials" {
  program = ["sh", "-c", <<-EOT
    jq -n \
      --arg ak "$${SCW_ACCESS_KEY:-$(scw config get access-key)}" \
      --arg sk "$${SCW_SECRET_KEY:-$(scw config get secret-key)}" \
      '{access_key:$ak, secret_key:$sk}'
  EOT
  ]
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
