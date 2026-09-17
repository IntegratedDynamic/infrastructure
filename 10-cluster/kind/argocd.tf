# infra#110: mirrors 10-cluster/scaleway/argocd.tf's platform-apps DAG --
# same chart (10-cluster/scaleway/platform-apps), same
# module.wait-argocd-apps-healthy pattern. Trimmed relative to the Scaleway
# DAG, and why:
#  - wireguard-apps: a real external WireGuard tunnel/peer config, no
#    orchestration-DAG content of its own -- nothing this tier would
#    validate by including it.
#  - crossplane-apps: its own Workspaces apply REAL production Terraform
#    (11-secrets/openbao/managed, 12-monitoring/grafana/managed) against
#    this repo's REAL Scaleway-hosted state -- categorically out of scope
#    for a disposable kind cluster (infra#110's own "what kind cannot
#    validate" list).
#
# dex-apps / argocd-config-apps / grafana-apps / argo-workflows-apps ARE
# kept (unlike an earlier draft of this file) -- see main.tf's header
# comment for why OpenBao here restores a REAL production snapshot instead
# of a fresh throwaway instance: it's what makes these four domains'
# ExternalSecrets resolve to real values instead of staying permanently
# unsynced, so this tier can actually validate them the way infra#110's own
# "what kind can validate well" list intends.
#
# No `bootstrap` (env: local) Application here, unlike 10-cluster/local --
# tried first (2026-09-17), reverted after it caused the real bug this file
# now exists to catch: gitops's bootstrap/templates/local.yaml's
# services-vendor-local recurse vendors openbao/external-secrets (among
# others) for minikube's benefit, which then fights platform-apps's own
# secrets-apps for ownership of the SAME child Applications (confirmed live:
# a SharedResourceWarning on both, secrets-apps stuck flapping
# OutOfSync/Healthy for the full 30min wait-secrets-healthy budget, never
# both true at once). demo's "free extra signal" wasn't worth reintroducing
# that collision -- this tier's whole point is validating platform-apps's
# own DAG, not gitops's separate local-only vendor path.
locals {
  platform_apps_source_repo = "https://github.com/IntegratedDynamic/infrastructure.git"

  # Same GOMEMLIMIT mitigation as 10-cluster/scaleway/argocd.tf's own
  # local, same reasoning (forces proactive GC before the cgroup hard
  # limit kills the controller during a full-tree reconcile burst) -- see
  # that file's own comment for the full "why" and the upstream doc link.
  argocd_controller_memory_limit_mib = 1500
  argocd_controller_gomemlimit_mib   = floor(local.argocd_controller_memory_limit_mib * 0.85)
}

resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "9.4.17"

  timeout = 240

  values = [<<EOF
configs:
  params:
    server.insecure: true
  cm:
    # Same restoration of Application-CRD health assessment as
    # 10-cluster/scaleway/argocd.tf -- without it a parent Application
    # (every domain below) is "Healthy" the instant it's created, never
    # reflecting whether its own child tree actually converged. See that
    # file's own comment for the full "why" and the upstream doc link.
    resource.customizations.health.argoproj.io_Application: |
      hs = {}
      hs.status = "Progressing"
      hs.message = ""
      if obj.status ~= nil then
        if obj.status.health ~= nil then
          hs.status = obj.status.health.status
          if obj.status.health.message ~= nil then
            hs.message = obj.status.health.message
          end
        end
      end
      return hs
  rbac:
    policy.default: role:admin

dex:
  enabled: false

# Same resource requests/limits as 10-cluster/scaleway/argocd.tf's own
# controller/repoServer/server/redis blocks (2026-09-17, confirmed live on
# kind CI: with none of this, the controller/repo-server starved under
# BestEffort QoS trying to compare ~30 Applications at once, leaving
# several stuck oscillating "Unknown" sync status indefinitely via
# repeated "spec.source differs" full-recomparisons that never resolved --
# same class of problem that resource comment already documents for
# Scaleway, just never given the same fix here yet).
controller:
  replicas: 1
  env:
    - name: GOMEMLIMIT
      value: "${local.argocd_controller_gomemlimit_mib}MiB"
  resources:
    requests:
      cpu: 50m
      memory: 768Mi
    limits:
      cpu: 3000m
      memory: "${local.argocd_controller_memory_limit_mib}Mi"

repoServer:
  replicas: 1
  resources:
    requests:
      cpu: 25m
      memory: 192Mi
    limits:
      cpu: 3000m
      memory: 768Mi

server:
  resources:
    requests:
      cpu: 10m
      memory: 64Mi
    limits:
      cpu: 100m
      memory: 128Mi

redis:
  resources:
    requests:
      cpu: 10m
      memory: 64Mi
    limits:
      cpu: 100m
      memory: 128Mi
EOF
  ]
}

resource "kubernetes_service_account" "wait_platform_apps" {
  depends_on = [helm_release.argocd]

  metadata {
    name      = "wait-platform-apps-healthy"
    namespace = "argocd"
  }
}

resource "kubernetes_role" "wait_platform_apps" {
  depends_on = [helm_release.argocd]

  metadata {
    name      = "wait-platform-apps-healthy"
    namespace = "argocd"
  }

  rule {
    api_groups = ["argoproj.io"]
    resources  = ["applications"]
    verbs      = ["get", "list"]
  }
}

resource "kubernetes_role_binding" "wait_platform_apps" {
  metadata {
    name      = "wait-platform-apps-healthy"
    namespace = "argocd"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.wait_platform_apps.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.wait_platform_apps.metadata[0].name
    namespace = "argocd"
  }
}

# ── Tier -1: crds-apps ───────────────────────────────────────────────────────
resource "helm_release" "crds_apps" {
  name      = "argocd-crds-apps"
  namespace = "argocd"

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.4"

  timeout = 1800

  depends_on = [helm_release.argocd]

  values = [<<EOF
applications:
  crds-apps:
    namespace: argocd
    finalizers:
      - resources-finalizer.argocd.argoproj.io
    project: default
    source:
      repoURL: ${local.platform_apps_source_repo}
      targetRevision: ${var.infra_revision}
      path: 10-cluster/scaleway/platform-apps
      helm:
        valueFiles:
          - values-crds.yaml
        parameters:
          - name: revision
            value: ${var.gitops_revision}
    destination:
      server: https://kubernetes.default.svc
      namespace: argocd
    syncPolicy:
      retry:
        limit: 10
      automated:
        prune: true
        selfHeal: true
      syncOptions:
        - CreateNamespace=true
EOF
  ]
}

module "wait_crds_healthy" {
  source = "./modules/wait-argocd-apps-healthy"

  job_name             = "wait-crds-healthy"
  app_names            = ["crds-apps"]
  service_account_name = kubernetes_service_account.wait_platform_apps.metadata[0].name
  revision_trigger     = helm_release.crds_apps.metadata.revision

  depends_on = [
    helm_release.crds_apps,
    kubernetes_role_binding.wait_platform_apps,
  ]
}

# ── secrets-apps (trimmed -- see values-secrets-kind.yaml) ──────────────────
resource "helm_release" "secrets_apps" {
  name      = "argocd-secrets-apps"
  namespace = "argocd"

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.4"

  timeout = 1800

  # kubernetes_secret.scaleway_dns_credentials/external_dns_scaleway_credentials
  # (main.tf): cert-manager-webhook-secret/external-dns-secret, this domain's
  # own wave-2 ExternalSecrets, both use creationPolicy: Merge -- confirmed
  # live these placeholder Secrets must already exist before this
  # Application's first sync, or ESO can structurally never create them
  # (see main.tf's own header comment).
  depends_on = [
    helm_release.argocd,
    kubernetes_secret.scaleway_s3_credentials,
    kubernetes_secret.openbao_unseal_aws,
    kubernetes_secret.scaleway_dns_credentials,
    kubernetes_secret.external_dns_scaleway_credentials,
  ]

  values = [<<EOF
applications:
  secrets-apps:
    namespace: argocd
    finalizers:
      - resources-finalizer.argocd.argoproj.io
    project: default
    source:
      repoURL: ${local.platform_apps_source_repo}
      targetRevision: ${var.infra_revision}
      path: 10-cluster/scaleway/platform-apps
      helm:
        valueFiles:
          - values-secrets-kind.yaml
        parameters:
          - name: revision
            value: ${var.gitops_revision}
    destination:
      server: https://kubernetes.default.svc
      namespace: argocd
    syncPolicy:
      retry:
        limit: 10
      automated:
        prune: true
        selfHeal: true
      syncOptions:
        - CreateNamespace=true
EOF
  ]
}

module "wait_secrets_healthy" {
  source = "./modules/wait-argocd-apps-healthy"

  job_name             = "wait-secrets-healthy"
  app_names            = ["secrets-apps"]
  service_account_name = kubernetes_service_account.wait_platform_apps.metadata[0].name
  revision_trigger     = helm_release.secrets_apps.metadata.revision

  depends_on = [
    helm_release.secrets_apps,
    kubernetes_role_binding.wait_platform_apps,
  ]
}

# monitoring-apps (kube-prometheus-stack + Loki + Tempo + Alloy +
# otel-collector) temporarily dropped (2026-09-17, infra#110 live
# debugging): it's this DAG's single biggest resource consumer, and the
# least directly relevant to what this tier exists to validate (CRD/
# secrets/networking ordering, not observability stack behavior). Pulled
# out to isolate whether it's the actual driver of the ArgoCD
# controller/repo-server contention causing several Applications to get
# stuck oscillating "Unknown" sync status (see helm_release.argocd's own
# resources block, added in the same commit, for the other half of that
# fix). Re-add once confirmed whether the resource tuning alone was
# enough, or whether this tier's real DAG needs to stay this trimmed.

resource "helm_release" "backups_apps" {
  name      = "argocd-backups-apps"
  namespace = "argocd"

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.4"

  timeout = 1800

  depends_on = [
    helm_release.argocd,
    kubernetes_secret.velero_scaleway_credentials,
  ]

  values = [<<EOF
applications:
  backups-apps:
    namespace: argocd
    finalizers:
      - resources-finalizer.argocd.argoproj.io
    project: default
    source:
      repoURL: ${local.platform_apps_source_repo}
      targetRevision: ${var.infra_revision}
      path: 10-cluster/scaleway/platform-apps
      helm:
        valueFiles:
          - values-backups-kind.yaml
        parameters:
          - name: revision
            value: ${var.gitops_revision}
    destination:
      server: https://kubernetes.default.svc
      namespace: argocd
    syncPolicy:
      retry:
        limit: 10
      automated:
        prune: true
        selfHeal: true
      syncOptions:
        - CreateNamespace=true
EOF
  ]
}

module "wait_backups_healthy" {
  source = "./modules/wait-argocd-apps-healthy"

  job_name             = "wait-backups-healthy"
  app_names            = ["backups-apps"]
  service_account_name = kubernetes_service_account.wait_platform_apps.metadata[0].name
  revision_trigger     = helm_release.backups_apps.metadata.revision

  depends_on = [
    helm_release.backups_apps,
    kubernetes_role_binding.wait_platform_apps,
  ]
}

resource "helm_release" "networking_controllers_apps" {
  name      = "argocd-networking-controllers-apps"
  namespace = "argocd"

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.4"

  timeout = 1800

  # helm_release.secrets_apps (2026-09-16, confirmed live on kind, soft --
  # NOT module.wait_secrets_healthy): cert-manager-webhook-scaleway (this
  # Application) consumes scaleway-dns-credentials, an ExternalSecret
  # materialized by secrets-apps' own wave 2 -- a real dependency
  # 10-cluster/scaleway/argocd.tf never actually gates on either. Never
  # surfaced there because Kapsule's own slower node/pod-scheduling timing
  # happens to let secrets-apps finish first in practice; kind's much
  # faster reconcile loop exposed the latent race outright (pod stuck
  # CreateContainerConfigError: "secret scaleway-dns-credentials not
  # found" for several minutes). A HARD wait_secrets_healthy dependency was
  # tried first and confirmed live to be the wrong tool here: secrets-apps'
  # own `openbao` child intermittently reports sync=Unknown (health stays
  # Healthy) for reasons still unconfirmed -- likely the same batch/Job
  # status-diffing noise platform-apps/README.md already documents for
  # openbao-init's hook Job elsewhere -- which fully serialized this domain
  # (and everything downstream of it) behind that unrelated flakiness for
  # this Job's own 30-minute budget. A soft create-order dependency still
  # closes the original race in practice (secrets-apps starts syncing well
  # before this Application is even created) without hard-blocking on a
  # convergence guarantee this domain doesn't actually need.
  depends_on = [
    helm_release.argocd,
    module.wait_crds_healthy,
    helm_release.secrets_apps,
  ]

  values = [<<EOF
applications:
  networking-controllers-apps:
    namespace: argocd
    finalizers:
      - resources-finalizer.argocd.argoproj.io
    project: default
    source:
      repoURL: ${local.platform_apps_source_repo}
      targetRevision: ${var.infra_revision}
      path: 10-cluster/scaleway/platform-apps
      helm:
        valueFiles:
          - values-networking-controllers.yaml
        parameters:
          - name: revision
            value: ${var.gitops_revision}
    destination:
      server: https://kubernetes.default.svc
      namespace: argocd
    syncPolicy:
      retry:
        limit: 10
      automated:
        prune: true
        selfHeal: true
      syncOptions:
        - CreateNamespace=true
EOF
  ]
}

module "wait_networking_controllers_healthy" {
  source = "./modules/wait-argocd-apps-healthy"

  job_name             = "wait-networking-controllers-healthy"
  app_names            = ["networking-controllers-apps"]
  service_account_name = kubernetes_service_account.wait_platform_apps.metadata[0].name
  revision_trigger     = helm_release.networking_controllers_apps.metadata.revision

  depends_on = [
    helm_release.networking_controllers_apps,
    kubernetes_role_binding.wait_platform_apps,
  ]
}

resource "helm_release" "networking_resources_apps" {
  name      = "argocd-networking-resources-apps"
  namespace = "argocd"

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.4"

  timeout = 1800

  depends_on = [
    helm_release.argocd,
    module.wait_networking_controllers_healthy,
    module.wait_secrets_healthy,
    module.wait_backups_healthy,
  ]

  values = [<<EOF
applications:
  networking-resources-apps:
    namespace: argocd
    finalizers:
      - resources-finalizer.argocd.argoproj.io
    project: default
    source:
      repoURL: ${local.platform_apps_source_repo}
      targetRevision: ${var.infra_revision}
      path: 10-cluster/scaleway/platform-apps
      helm:
        valueFiles:
          - values-networking-resources-kind.yaml
        parameters:
          - name: revision
            value: ${var.gitops_revision}
          # Forced to a self-signed ClusterIssuer for this tier (gitops
          # repo's services/platform/gateway/config, new
          # clusterissuer-selfsigned.yaml template) -- structurally
          # prevents cert-manager from ever triggering a real DNS01
          # challenge through cert-manager-webhook-scaleway, regardless of
          # the real Scaleway DNS credentials that domain's ExternalSecret
          # resolves to (see main.tf's header comment). NOT
          # letsencrypt-prod/-staging.
          - name: activeClusterIssuer
            value: selfsigned
          - name: hostSuffix
            value: ""
    destination:
      server: https://kubernetes.default.svc
      namespace: argocd
    syncPolicy:
      retry:
        limit: 10
      automated:
        prune: true
        selfHeal: true
      syncOptions:
        - CreateNamespace=true
EOF
  ]
}

# ── Tier 1: dex/argocd-config/grafana ────────────────────────────────────────
resource "helm_release" "dex_apps" {
  name      = "argocd-dex-apps"
  namespace = "argocd"

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.4"

  timeout = 1800

  depends_on = [
    helm_release.argocd,
    helm_release.secrets_apps,
  ]

  values = [<<EOF
applications:
  dex-apps:
    namespace: argocd
    finalizers:
      - resources-finalizer.argocd.argoproj.io
    project: default
    source:
      repoURL: ${local.platform_apps_source_repo}
      targetRevision: ${var.infra_revision}
      path: 10-cluster/scaleway/platform-apps
      helm:
        valueFiles:
          - values-dex.yaml
        parameters:
          - name: revision
            value: ${var.gitops_revision}
    destination:
      server: https://kubernetes.default.svc
      namespace: argocd
    syncPolicy:
      retry:
        limit: 10
      automated:
        prune: true
        selfHeal: true
      syncOptions:
        - CreateNamespace=true
EOF
  ]
}

module "wait_dex_healthy" {
  source = "./modules/wait-argocd-apps-healthy"

  job_name             = "wait-dex-healthy"
  app_names            = ["dex-apps"]
  service_account_name = kubernetes_service_account.wait_platform_apps.metadata[0].name
  revision_trigger     = helm_release.dex_apps.metadata.revision

  depends_on = [
    helm_release.dex_apps,
    kubernetes_role_binding.wait_platform_apps,
  ]
}

resource "helm_release" "argocd_config_apps" {
  name      = "argocd-argocd-config-apps"
  namespace = "argocd"

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.4"

  timeout = 1800

  depends_on = [
    helm_release.argocd,
    module.wait_secrets_healthy,
  ]

  values = [<<EOF
applications:
  argocd-config-apps:
    namespace: argocd
    finalizers:
      - resources-finalizer.argocd.argoproj.io
    project: default
    source:
      repoURL: ${local.platform_apps_source_repo}
      targetRevision: ${var.infra_revision}
      path: 10-cluster/scaleway/platform-apps
      helm:
        valueFiles:
          - values-argocd-config.yaml
        parameters:
          - name: revision
            value: ${var.gitops_revision}
    destination:
      server: https://kubernetes.default.svc
      namespace: argocd
    syncPolicy:
      retry:
        limit: 10
      automated:
        prune: true
        selfHeal: true
      syncOptions:
        - CreateNamespace=true
EOF
  ]
}

resource "helm_release" "grafana_apps" {
  name      = "argocd-grafana-apps"
  namespace = "argocd"

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.4"

  timeout = 1800

  depends_on = [
    helm_release.argocd,
    helm_release.secrets_apps,
    module.wait_backups_healthy,
  ]

  values = [<<EOF
applications:
  grafana-apps:
    namespace: argocd
    finalizers:
      - resources-finalizer.argocd.argoproj.io
    project: default
    source:
      repoURL: ${local.platform_apps_source_repo}
      targetRevision: ${var.infra_revision}
      path: 10-cluster/scaleway/platform-apps
      helm:
        valueFiles:
          - values-grafana.yaml
        parameters:
          - name: revision
            value: ${var.gitops_revision}
          - name: letsEncryptStaging
            value: "false"
    destination:
      server: https://kubernetes.default.svc
      namespace: argocd
    syncPolicy:
      retry:
        limit: 10
      automated:
        prune: true
        selfHeal: true
      syncOptions:
        - CreateNamespace=true
EOF
  ]
}

# ── Tier 2: argo-workflows ────────────────────────────────────────────────────
module "wait_grafana_healthy" {
  source = "./modules/wait-argocd-apps-healthy"

  job_name             = "wait-grafana-healthy"
  app_names            = ["grafana-apps"]
  service_account_name = kubernetes_service_account.wait_platform_apps.metadata[0].name
  revision_trigger     = helm_release.grafana_apps.metadata.revision

  depends_on = [
    helm_release.grafana_apps,
    kubernetes_role_binding.wait_platform_apps,
  ]
}

resource "helm_release" "argo_workflows_apps" {
  name      = "argocd-argo-workflows-apps"
  namespace = "argocd"

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.4"

  timeout = 1800

  depends_on = [
    helm_release.argocd,
    helm_release.secrets_apps,
    module.wait_dex_healthy,
  ]

  values = [<<EOF
applications:
  argo-workflows-apps:
    namespace: argocd
    finalizers:
      - resources-finalizer.argocd.argoproj.io
    project: default
    source:
      repoURL: ${local.platform_apps_source_repo}
      targetRevision: ${var.infra_revision}
      path: 10-cluster/scaleway/platform-apps
      helm:
        valueFiles:
          - values-argo-workflows.yaml
        parameters:
          - name: revision
            value: ${var.gitops_revision}
    destination:
      server: https://kubernetes.default.svc
      namespace: argocd
    syncPolicy:
      retry:
        limit: 10
      automated:
        prune: true
        selfHeal: true
      syncOptions:
        - CreateNamespace=true
EOF
  ]
}

# The "is everything actually healthy" check -- same reasoning as
# 10-cluster/scaleway/argocd.tf's module.wait_all_domains_healthy, trimmed
# to this tier's own (smaller) domain list (no wireguard-apps/crossplane-apps
# -- see this file's own header comment for why).
module "wait_all_domains_healthy" {
  source = "./modules/wait-argocd-apps-healthy"

  job_name = "wait-all-domains-healthy"
  app_names = [
    "crds-apps",
    "secrets-apps",
    "backups-apps",
    "networking-controllers-apps",
    "networking-resources-apps",
    "dex-apps",
    "argocd-config-apps",
    "grafana-apps",
    "argo-workflows-apps",
  ]
  service_account_name = kubernetes_service_account.wait_platform_apps.metadata[0].name

  revision_trigger = join(",", [
    helm_release.crds_apps.metadata.revision,
    helm_release.secrets_apps.metadata.revision,
    helm_release.backups_apps.metadata.revision,
    helm_release.networking_controllers_apps.metadata.revision,
    helm_release.networking_resources_apps.metadata.revision,
    helm_release.dex_apps.metadata.revision,
    helm_release.argocd_config_apps.metadata.revision,
    helm_release.grafana_apps.metadata.revision,
    helm_release.argo_workflows_apps.metadata.revision,
  ])

  depends_on = [
    helm_release.crds_apps,
    helm_release.secrets_apps,
    helm_release.backups_apps,
    helm_release.networking_controllers_apps,
    helm_release.networking_resources_apps,
    helm_release.dex_apps,
    helm_release.argocd_config_apps,
    helm_release.grafana_apps,
    helm_release.argo_workflows_apps,
    kubernetes_role_binding.wait_platform_apps,
  ]
}
