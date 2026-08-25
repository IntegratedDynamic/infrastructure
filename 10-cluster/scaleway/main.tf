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

# ── Secrets/monitoring/backups direct provisioning (infra#84) ───────────────
#
# monitoring/velero namespaces: Terraform-managed for the same reason
# kubernetes_namespace.openbao above already was — the Secrets below must
# exist before ArgoCD's own CreateNamespace=true sync gets a chance to run,
# not after. external-secrets/secrets-sync namespaces get no such treatment
# (see argocd-platform-apps/README.md's "Namespace decision") since nothing
# Terraform-side writes into them.
resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
  }
  depends_on = [scaleway_k8s_pool.default]
}

resource "kubernetes_namespace" "velero" {
  metadata {
    name = "velero"
  }
  depends_on = [scaleway_k8s_pool.default]
}

# Confirmed live (2026-08-25, reproduced twice): destroying this namespace
# hangs indefinitely (~5min, then `terraform destroy` errors "context
# deadline exceeded") on Velero's own Restore custom resources (created by
# gitops repo's cert-restore/grafana-restore PreSync hooks), which carry
# `restores.velero.io/external-resources-finalizer` -- a finalizer only
# Velero's own controller ever removes, by reconciling it. Kubernetes gives
# no ordering guarantee that a namespace's contained custom resources get
# their finalizers processed before the controller that owns those
# finalizers is itself torn down as part of the SAME cascading namespace
# delete -- a genuine race, not just slowness (a longer timeout doesn't
# reliably fix it, since the controller can lose the race regardless of
# how long we wait). Since a `terraform destroy` tears down the whole
# cluster anyway, there's no external state left to protect by waiting for
# Velero's own cleanup -- this proactively strips finalizers from the
# known Restore objects right before the namespace itself is destroyed,
# instead of hoping the race goes the other way.
#
# Deliberately curl-based, not kubectl-based: this root's execution
# environment (an admin's machine, or CI, per this repo's own convention)
# is not guaranteed to have kubectl installed, only whatever the
# provisioner itself can assume -- curl ships on essentially every base
# OS/CI image already, kubectl does not. Named restore objects, not a
# discovery loop (`kubectl api-resources`/`get` equivalent), for the same
# reason -- there is no portable curl-only way to enumerate a CRD's
# instances without a JSON-parsing tool (jq etc.) that's just as
# unguaranteed as kubectl itself. Add to this list if a future gitops-repo
# PreSync restore hook creates another named Restore
# (services/platform/gateway/config's cert-restore and
# services/platform/monitoring/grafana-chart's grafana-restore are the
# only two today).
#
# Connection details are captured in `triggers` (not referenced directly
# in the provisioner) because a destroy-time provisioner may only
# reference `self` or input variables, never other resources -- Terraform
# can't guarantee those resources' state still exists during a partial
# destroy. Stashing them here at create time, read back via `self.triggers`
# at destroy time, is the standard workaround.
#
# depends_on BOTH the namespace AND argocd.tf's helm_release.argocd_platform_apps
# -- confirmed live (2026-08-25) that depending on the namespace alone was
# not enough: the namespace's OWN destroy is itself gated behind that
# release finishing its cascade-delete first (same secret-chain ordering
# fix as kubernetes_namespace.openbao above), which can take many minutes.
# With only the namespace as a dependency, Terraform was free to run this
# cleanup as early as possible in the whole destroy -- long before the
# namespace destroy was actually attempted -- leaving a real window where
# Velero, still running, recreates the exact Restore objects this had
# already stripped. Depending on both makes this run immediately adjacent
# to the namespace destroy it exists to unblock, not whenever Terraform
# happens to schedule it.
resource "null_resource" "velero_namespace_predelete_cleanup" {
  depends_on = [kubernetes_namespace.velero, helm_release.argocd_platform_apps]

  triggers = {
    host      = scaleway_k8s_cluster.this.kubeconfig[0].host
    token     = scaleway_k8s_cluster.this.kubeconfig[0].token
    namespace = kubernetes_namespace.velero.metadata[0].name
  }

  provisioner "local-exec" {
    when       = destroy
    on_failure = continue

    # curl -k (skip TLS verify): acceptable here -- this cluster is
    # mid-destroy, and the token already came straight out of Terraform
    # state on the same machine, so skipping CA validation adds no
    # meaningful exposure. `|| true` per call: a 404 (object never
    # existed, e.g. a fresh cluster with no restore history yet) is a
    # normal outcome, not a failure.
    command = <<-EOT
      set -eu
      for name in cert-secrets-restore grafana-pvc-restore; do
        echo "Stripping finalizers from restores.velero.io/$name (if present) before namespace delete..."
        curl -sS -k -o /dev/null \
          -X PATCH \
          -H "Authorization: Bearer ${self.triggers.token}" \
          -H "Content-Type: application/merge-patch+json" \
          -d '{"metadata":{"finalizers":[]}}' \
          "${self.triggers.host}/apis/velero.io/v1/namespaces/${self.triggers.namespace}/restores/$name" \
          || true
      done
    EOT
  }
}

# thanos-objstore-config / loki-s3-credentials / tempo-s3-credentials /
# velero-scaleway-credentials: written directly here instead of via
# OpenBao+ESO's ExternalSecret round-trip (gitops repo's former
# monitoring/thanos-secret, loki-secret, tempo-secret, velero/secret charts
# — deleted, see platform-apps/README.md's "The secret-delivery pattern").
# Terraform already originates all four credentials (03-storage/scaleway's
# workload identities, read here via the same data.terraform_remote_state.backup_scaleway
# 11-secrets/openbao/managed also reads) so there's no reason to hand them
# to ESO just to hand them back — OpenBao stays the audited source of truth
# via 11-secrets/openbao/managed's own vault_kv_secret_v2 writes (unchanged,
# dual-written independently of this Secret).
resource "kubernetes_secret" "thanos_objstore_config" {
  metadata {
    name      = "thanos-objstore-config"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  data = {
    # Matches gitops repo's former monitoring/thanos-secret ExternalSecret
    # template exactly (single objstore.yaml key, Thanos's own format:
    # https://thanos.io/tip/thanos/storage.md/#s3) — bucket/endpoint/region
    # kept in sync by hand with 03-storage/scaleway/env/*.tfvars' thanos
    # entry, same convention that chart's values.yaml already documented.
    "objstore.yaml" = yamlencode({
      type = "S3"
      config = {
        bucket     = data.terraform_remote_state.backup_scaleway.outputs.thanos_bucket_name
        endpoint   = "s3.fr-par.scw.cloud"
        region     = "fr-par"
        access_key = data.terraform_remote_state.backup_scaleway.outputs.thanos_workload_access_key
        secret_key = data.terraform_remote_state.backup_scaleway.outputs.thanos_workload_secret_key
      }
    })
  }
}

resource "kubernetes_secret" "loki_s3_credentials" {
  metadata {
    name      = "loki-s3-credentials"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  data = {
    AWS_ACCESS_KEY_ID     = data.terraform_remote_state.backup_scaleway.outputs.loki_workload_access_key
    AWS_SECRET_ACCESS_KEY = data.terraform_remote_state.backup_scaleway.outputs.loki_workload_secret_key
  }
}

resource "kubernetes_secret" "tempo_s3_credentials" {
  metadata {
    name      = "tempo-s3-credentials"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  data = {
    AWS_ACCESS_KEY_ID     = data.terraform_remote_state.backup_scaleway.outputs.tempo_workload_access_key
    AWS_SECRET_ACCESS_KEY = data.terraform_remote_state.backup_scaleway.outputs.tempo_workload_secret_key
  }
}

resource "kubernetes_secret" "velero_scaleway_credentials" {
  metadata {
    name      = "velero-scaleway-credentials"
    namespace = kubernetes_namespace.velero.metadata[0].name
  }

  data = {
    # Matches gitops repo's former velero/secret ExternalSecret template
    # exactly (single "cloud" key, AWS shared-config/INI format
    # velero-plugin-for-aws reads via credentials.existingSecret).
    cloud = <<-EOT
      [default]
      aws_access_key_id=${data.terraform_remote_state.backup_scaleway.outputs.velero_workload_access_key}
      aws_secret_access_key=${data.terraform_remote_state.backup_scaleway.outputs.velero_workload_secret_key}
    EOT
  }
}
