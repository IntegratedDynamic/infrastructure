# infra#110: fast, free, on-every-PR validation tier for the
# crds-apps -> secrets-apps -> monitoring/backups/networking-* platform-apps
# DAG that 10-cluster/scaleway/argocd.tf drives against a real Kapsule
# cluster. This root reuses that SAME chart
# (10-cluster/platform-apps, shared at the domain root -- infra#115) via the
# helm_release blocks in argocd.tf (this directory) -- never a forked copy --
# so the two tiers can't silently drift apart.
#
# OpenBao is bootstrapped from a REAL restore of the production raft
# snapshot (gitops repo's services/platform/openbao/init, values-scaleway.yaml
# unmodified -- same chart, same restore-job.yaml, no kind-specific fork),
# not a fresh throwaway instance. This was a deliberate choice, not the
# obvious one: seal "awskms" wraps OpenBao's barrier key using the real
# production KMS key, so a snapshot taken from that instance can only be
# unsealed by a target ALSO running that same seal config with real
# credentials able to call that same KMS key -- there's no narrower-privilege
# way to make a real snapshot restorable. The alternative (a fresh,
# throwaway Shamir-sealed instance with no real secret material) was
# rejected because it can't give grafana-apps/
# argo-workflows-apps below anything real to consume, defeating the point of
# validating them at all. Accepted trade-off: this tier's CI needs real
# AWS KMS decrypt + real Scaleway backup-bucket read access.
#
# What's still deliberately kept FAKE despite that: thanos/loki/tempo/velero's
# Object Storage credentials (this repo's own Terraform-direct secrets, not
# ESO-delivered even in production) stay placeholder values below -- a real
# credential here would make kind CI actually push telemetry/backup data
# into PRODUCTION buckets on every PR run. Same reasoning kept openbao's own
# snapshotAgent disabled for kind (values-kind.yaml, gitops repo) -- restore
# real, never push from a throwaway cluster back into the real backup
# bucket. external-dns/cert-manager-webhook-scaleway get their real
# credentials via the restored OpenBao KV, same as production, but are
# structurally blocked from mutating real DNS regardless: gateway-config's
# activeClusterIssuer is forced to "selfsigned" (argocd.tf) so cert-manager
# never triggers a DNS01 challenge at all, and external-dns runs with
# dryRun: true (values-kind.yaml, gitops repo) so its own reconcile loop
# never calls the provider's write API -- neither depends on credentials
# being fake, both are structural.
#
# scaleway_dns_credentials/external_dns_scaleway_credentials below DO still
# need a Terraform-seeded placeholder (confirmed live, missed in an earlier
# draft of this file): both ExternalSecrets use creationPolicy: Merge
# (gitops repo's cert-manager/webhook-secret and external-dns/secret
# charts), which -- by design, see that chart's own comment -- refuses to
# CREATE the target Secret from nothing; it only merges keys into an
# object that already exists. 10-cluster/scaleway/main.tf seeds both
# Secrets directly for exactly this reason (so ESO has something to merge
# into during a from-scratch bootstrap); this tier needs the same seed, or
# the pod consuming it sits in CreateContainerConfigError forever, with no
# self-heal possible at all -- ESO can never satisfy a Merge target it's
# structurally forbidden from creating.

# The core platform this cluster runs on (buckets, unseal key) arrives
# as variables.core_*, from the core states, through Terragrunt: see
# live/clusters/core.hcl.

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
    bucket                = var.core_storage.bucket_name
    AWS_ACCESS_KEY_ID     = var.core_storage.workload_access_key
    AWS_SECRET_ACCESS_KEY = var.core_storage.workload_secret_key
  }
}

resource "kubernetes_secret" "openbao_unseal_aws" {
  metadata {
    name      = "openbao-unseal-aws"
    namespace = kubernetes_namespace.openbao.metadata[0].name
  }

  data = {
    AWS_ACCESS_KEY_ID     = var.core_unseal.openbao_unseal_access_key_id
    AWS_SECRET_ACCESS_KEY = var.core_unseal.openbao_unseal_secret_access_key
  }
}

# ── Dummy credentials for the Terraform-direct secrets (infra#110) ──────────
#
# 10-cluster/scaleway/main.tf writes these same Secret names from real
# 03-storage/scaleway state; this tier writes them with placeholder values
# instead -- unlike OpenBao's restore above, there is no reason to let
# kind CI push real telemetry/backup data into these production buckets.
# Goal is narrower: let the consuming pod actually schedule (mounting a
# Secret that doesn't exist at all is a hard CreateContainerConfigError,
# not a graceful degrade) -- not for the real push/pull to succeed. Expect
# thanos/loki/tempo/velero's own reconcile loops to show real, accepted
# errors against these fake values.
# thanos_objstore_config/loki_s3_credentials/tempo_s3_credentials
# (monitoring namespace) temporarily removed with helm_release.monitoring_apps
# itself -- see argocd.tf's own comment on that removal. Re-add alongside it.
resource "kubernetes_namespace" "velero" {
  metadata {
    name = "velero"
  }
}

resource "kubernetes_secret" "velero_scaleway_credentials" {
  metadata {
    name      = "velero-scaleway-credentials"
    namespace = kubernetes_namespace.velero.metadata[0].name
  }

  # AWS-credentials-file INI format -- velero's aws plugin's own expected
  # shape for this key, same as 10-cluster/scaleway/main.tf's real secret.
  data = {
    cloud = "[default]\naws_access_key_id=kind-fake-access-key\naws_secret_access_key=kind-fake-secret-key\n"
  }
}

resource "kubernetes_namespace" "external_dns" {
  metadata {
    name = "external-dns"
  }
}

resource "kubernetes_namespace" "cert_manager" {
  metadata {
    name = "cert-manager"
  }
}

# Seed only -- ESO's own ExternalSecret (creationPolicy: Merge) immediately
# overwrites these placeholder keys with the real value from the restored
# OpenBao KV, same "ESO keeps reconciling this exact object" coexistence
# 10-cluster/scaleway/main.tf's own identical resource already documents.
# ignore_changes mirrors that resource too: without it, Terraform's
# full-metadata management fights ESO over the tracking annotations/labels
# it adds on every refresh.
resource "kubernetes_secret" "scaleway_dns_credentials" {
  metadata {
    name      = "scaleway-dns-credentials"
    namespace = kubernetes_namespace.cert_manager.metadata[0].name
  }

  data = {
    SCW_ACCESS_KEY = "kind-fake-access-key"
    SCW_SECRET_KEY = "kind-fake-secret-key"
  }

  lifecycle {
    ignore_changes = [metadata[0].annotations, metadata[0].labels]
  }
}

resource "kubernetes_secret" "external_dns_scaleway_credentials" {
  metadata {
    name      = "external-dns-scaleway-credentials"
    namespace = kubernetes_namespace.external_dns.metadata[0].name
  }

  data = {
    SCW_ACCESS_KEY = "kind-fake-access-key"
    SCW_SECRET_KEY = "kind-fake-secret-key"
  }

  lifecycle {
    ignore_changes = [metadata[0].annotations, metadata[0].labels]
  }
}
