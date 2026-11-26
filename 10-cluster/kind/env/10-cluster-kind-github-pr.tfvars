# Base tfvars for kind.yml's own run of this root -- named github-pr since
# that's the only real invocation context this file exists for today (no
# local-dev counterpart the way 10-cluster/scaleway's env/*.tfvars has one
# per real environment; this root has no backend/workspace at all -- see
# version.tf's own header comment -- so this filename is purely the
# "which set of default variable values" convention CLAUDE.md documents,
# not a workspace name).
#
# infra_revision is deliberately NOT set here: it's the PR's own head ref,
# genuinely dynamic per run -- kind.yml appends it fresh into a COPY of
# this file every run, same "generate a per-run tfvars, never commit the
# generated one" pattern .github/workflows/scaleway-ephemeral.yml already
# uses for the exact same reason (infra_revision there too).
#
# gitops_revision is deliberately NOT set here either: it follows
# 10-cluster/kind/variables.tf's "main" default. It used to be pinned to gitops's
# epic/kind-ci-fast-tier branch, because this tier's companion gitops-side fixes
# (the values-kind.yaml of openbao/velero/external-dns/cert-restore/grafana-restore,
# velero's enableCSISnapshotClass, gateway/config's clusterissuer-selfsigned.yaml,
# openbao/init's hook-delete-policy removal) lived only on that branch. All of them
# are on gitops main now, byte for byte (checked file by file, 2026-11-25), so the
# pin is gone. Left in place it would also have broken this tier: the restored
# OpenBao snapshot no longer has kv/apps/dex/credentials (Dex was removed, infra
# issue #135), which that branch's grafana-secret still reads, so the Grafana chain
# of secrets-apps never turned Healthy.

# infra#113: the whole platform-apps DAG this tier validates. Trimmed
# relative to 10-cluster/scaleway/env/10-cluster-scaleway-staging.tfvars' own
# domains, and why:
#  - wireguard-apps: a real external WireGuard tunnel/peer config, no
#    orchestration-DAG content of its own -- nothing this tier would
#    validate by including it.
#  - crossplane-apps: its own Workspaces apply REAL production Terraform
#    (11-secrets/openbao/managed, 12-monitoring/grafana/managed) against
#    this repo's REAL Scaleway-hosted state -- categorically out of scope
#    for a disposable kind cluster.
#  - monitoring-apps: temporarily dropped (2026-09-17, infra#110 live
#    debugging) -- this DAG's single biggest resource consumer, least
#    directly relevant to what this tier validates (CRD/secrets/networking
#    ordering, not observability stack behavior).
#  - No `bootstrap` (env: local) Application -- tried first, reverted
#    after it caused a real bug: gitops's bootstrap/templates/local.yaml's
#    services-vendor-local recurse vendors openbao/external-secrets (among
#    others) for minikube's benefit, fighting platform-apps's own
#    secrets-apps for ownership of the SAME child Applications (confirmed
#    live: a SharedResourceWarning on both, secrets-apps stuck flapping
#    OutOfSync/Healthy for the full 30min wait-secrets-healthy budget,
#    never both true at once). This tier's whole point is validating
#    platform-apps's own DAG, not gitops's separate local-only vendor path.
#
# keda-apps IS kept, since 2026-11-26 (it was missing, and this tier was red
# because of it): gitops main routes grafana and argocd-server through the KEDA
# HTTP add-on (charts/cold-start: HTTPScaledObject/InterceptorRoute, plus a
# backendRef to the interceptor Service in the `keda` namespace). Without that
# domain those CRDs and that Service do not exist: `grafana` and
# `argocd-config-gateway` fail their sync ("one or more synchronization tasks
# are not valid") and both *-gateway routes stay Degraded. The tier only went
# red when its gitops pin to epic/kind-ci-fast-tier (which predates cold-start)
# was dropped, so nothing showed it earlier. Same domain as the staging one.
#
# dex-apps / argocd-config-apps / grafana-apps / argo-workflows-apps ARE
# kept -- see main.tf's own header comment for why OpenBao here restores a
# REAL production snapshot instead of a fresh throwaway instance: it's
# what makes these four domains' ExternalSecrets resolve to real values
# instead of staying permanently unsynced, so this tier can actually
# validate them.
#
# networking-controllers-apps also gates on secrets-apps here, NOT just
# crds-apps like the Scaleway graph does -- confirmed live 2026-09-16 on
# kind: cert-manager-webhook-scaleway (this domain) consumes
# scaleway-dns-credentials, an ExternalSecret secrets-apps' own wave 2
# materializes -- a real dependency the Scaleway graph never surfaced
# because Kapsule's slower node/pod-scheduling timing happens to let
# secrets-apps finish first in practice; kind's much faster reconcile loop
# exposed the latent race outright.
#
# crds-apps/secrets-apps/backups-apps/networking-controllers-apps/
# grafana-apps need no needs_* flags themselves -- they're the six
# well-known gate domains 10-cluster/modules/platform-apps-dag/main.tf
# hardcodes by name, never consumers of each other (confirmed against
# every edge here and in the Scaleway graph).
domains = {
  crds-apps = {
    value_files = ["values-crds.yaml"]
  }

  secrets-apps = {
    value_files = ["values-secrets-kind.yaml"]
  }

  backups-apps = {
    value_files = ["values-backups-kind.yaml"]
  }

  networking-controllers-apps = {
    value_files   = ["values-networking-controllers.yaml"]
    needs_crds    = true
    needs_secrets = true
  }

  networking-resources-apps = {
    value_files = ["values-networking-resources-kind.yaml"]
    parameters = [
      # Forced to a self-signed ClusterIssuer for this tier (gitops repo's
      # services/platform/gateway/config, clusterissuer-selfsigned.yaml
      # template) -- structurally prevents cert-manager from ever
      # triggering a real DNS01 challenge through
      # cert-manager-webhook-scaleway, regardless of the real Scaleway DNS
      # credentials that domain's ExternalSecret resolves to. NOT
      # letsencrypt-prod/-staging.
      { name = "activeClusterIssuer", value = "selfsigned" },
      { name = "hostSuffix", value = "" },
    ]
    needs_networking_controllers = true
    needs_secrets                = true
    needs_backups                = true
    # argocd-config-gateway renders the cold-start HTTPScaledObject/
    # InterceptorRoute (CRDs from keda-apps' HTTP Add-on). Gated here so the
    # order is deterministic; the staging graph leaves it to ArgoCD's sync
    # retries.
    needs_keda = true
  }

  grafana-apps = {
    value_files = ["values-grafana.yaml"]
    parameters = [
      { name = "letsEncryptStaging", value = "false" },
    ]
    needs_secrets = true
    needs_backups = true
    # No needs_keda here although grafana renders the cold-start
    # HTTPScaledObject: grafana-apps is itself one of the gate domains, and a
    # gate may only set needs_crds (platform-apps-dag/main.tf), so the flag
    # would be silently ignored. Same as the staging graph: ArgoCD's own sync
    # retries cover the CRDs arriving from keda-apps.
  }

  # KEDA + HTTP Add-on. Its chart generates ServiceMonitors, so the
  # monitoring.coreos.com CRDs from crds-apps must be Established first (same
  # as the staging graph). Needs no Secret.
  keda-apps = {
    value_files = ["values-keda.yaml"]
    needs_crds  = true
  }
}
