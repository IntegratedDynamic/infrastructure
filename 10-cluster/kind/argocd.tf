# infra#110 + infra#113: mirrors 10-cluster/scaleway/argocd.tf's
# platform-apps DAG through the SAME shared modules that root now uses
# (10-cluster/modules/argocd-platform-domain, wait-argocd-apps-healthy,
# argocd-wait-rbac, argocd-base-values) -- not a hand-copied duplicate of
# its Terraform. Both roots' own argocd.tf now hold only what's genuinely
# environment-specific: WHICH domains exist, in WHAT order, gated by WHAT,
# and each domain's own valueFiles/parameters. See
# 10-cluster/scaleway/platform-apps/README.md for the platform-wide DAG this
# wiring encodes, and 10-cluster/modules/argocd-platform-domain/main.tf for
# why the per-domain module deliberately does NOT also own its wait gate
# (soft vs. hard cross-domain dependencies would otherwise collapse into
# always-hard).
#
# Trimmed relative to the Scaleway DAG, and why:
#  - wireguard-apps: a real external WireGuard tunnel/peer config, no
#    orchestration-DAG content of its own -- nothing this tier would
#    validate by including it.
#  - crossplane-apps: its own Workspaces apply REAL production Terraform
#    (11-secrets/openbao/managed, 12-monitoring/grafana/managed) against
#    this repo's REAL Scaleway-hosted state -- categorically out of scope
#    for a disposable kind cluster (infra#110's own "what kind cannot
#    validate" list).
#  - monitoring-apps: temporarily dropped (2026-09-17, infra#110 live
#    debugging) -- this DAG's single biggest resource consumer, least
#    directly relevant to what this tier validates (CRD/secrets/networking
#    ordering, not observability stack behavior). See helm_release.argocd's
#    own resources (module.argocd_base_values) for the other half of the
#    contention fix this isolated.
#  - No `bootstrap` (env: local) Application here, unlike the deleted
#    10-cluster/local -- tried first (2026-09-17), reverted after it caused
#    a real bug: gitops's bootstrap/templates/local.yaml's
#    services-vendor-local recurse vendors openbao/external-secrets (among
#    others) for minikube's benefit, fighting platform-apps's own
#    secrets-apps for ownership of the SAME child Applications (confirmed
#    live: a SharedResourceWarning on both, secrets-apps stuck flapping
#    OutOfSync/Healthy for the full 30min wait-secrets-healthy budget, never
#    both true at once). This tier's whole point is validating
#    platform-apps's own DAG, not gitops's separate local-only vendor path.
#
# dex-apps / argocd-config-apps / grafana-apps / argo-workflows-apps ARE
# kept -- see main.tf's header comment for why OpenBao here restores a REAL
# production snapshot instead of a fresh throwaway instance: it's what
# makes these four domains' ExternalSecrets resolve to real values instead
# of staying permanently unsynced, so this tier can actually validate them.
locals {
  platform_apps_source_repo = "https://github.com/IntegratedDynamic/infrastructure.git"
  platform_apps_path        = "10-cluster/scaleway/platform-apps"
}

module "argocd_base_values" {
  source = "../modules/argocd-base-values"
}

resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "9.4.17"

  timeout = 240

  values = [
    module.argocd_base_values.values,
    <<-EOF
    configs:
      rbac:
        # No OIDC/Dex login wired up for this ephemeral, single-use tier
        # (unlike 10-cluster/scaleway's shared Dex) -- every access here is
        # already the CI job's own kubeconfig admin, so there's no separate
        # audience to restrict.
        policy.default: role:admin
    EOF
  ]
}

module "wait_rbac" {
  source = "../modules/argocd-wait-rbac"

  depends_on = [helm_release.argocd]
}

# ── Tier -1: crds-apps ───────────────────────────────────────────────────────
module "crds_apps" {
  source = "../modules/argocd-platform-domain"

  name            = "crds-apps"
  source_repo     = local.platform_apps_source_repo
  target_revision = var.infra_revision
  source_path     = local.platform_apps_path
  value_files     = ["values-crds.yaml"]
  parameters      = [{ name = "revision", value = var.gitops_revision }]

  depends_on = [helm_release.argocd]
}

module "wait_crds_healthy" {
  source = "../modules/wait-argocd-apps-healthy"

  job_name             = "wait-crds-healthy"
  app_names            = [module.crds_apps.application_name]
  service_account_name = module.wait_rbac.service_account_name
  revision_trigger     = module.crds_apps.helm_release_revision

  depends_on = [module.crds_apps, module.wait_rbac]
}

# ── secrets-apps (trimmed -- see values-secrets-kind.yaml) ──────────────────
module "secrets_apps" {
  source = "../modules/argocd-platform-domain"

  name            = "secrets-apps"
  source_repo     = local.platform_apps_source_repo
  target_revision = var.infra_revision
  source_path     = local.platform_apps_path
  value_files     = ["values-secrets-kind.yaml"]
  parameters      = [{ name = "revision", value = var.gitops_revision }]

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
}

module "wait_secrets_healthy" {
  source = "../modules/wait-argocd-apps-healthy"

  job_name             = "wait-secrets-healthy"
  app_names            = [module.secrets_apps.application_name]
  service_account_name = module.wait_rbac.service_account_name
  revision_trigger     = module.secrets_apps.helm_release_revision

  depends_on = [module.secrets_apps, module.wait_rbac]
}

module "backups_apps" {
  source = "../modules/argocd-platform-domain"

  name            = "backups-apps"
  source_repo     = local.platform_apps_source_repo
  target_revision = var.infra_revision
  source_path     = local.platform_apps_path
  value_files     = ["values-backups-kind.yaml"]
  parameters      = [{ name = "revision", value = var.gitops_revision }]

  depends_on = [
    helm_release.argocd,
    kubernetes_secret.velero_scaleway_credentials,
  ]
}

module "wait_backups_healthy" {
  source = "../modules/wait-argocd-apps-healthy"

  job_name             = "wait-backups-healthy"
  app_names            = [module.backups_apps.application_name]
  service_account_name = module.wait_rbac.service_account_name
  revision_trigger     = module.backups_apps.helm_release_revision

  depends_on = [module.backups_apps, module.wait_rbac]
}

module "networking_controllers_apps" {
  source = "../modules/argocd-platform-domain"

  name            = "networking-controllers-apps"
  source_repo     = local.platform_apps_source_repo
  target_revision = var.infra_revision
  source_path     = local.platform_apps_path
  value_files     = ["values-networking-controllers.yaml"]
  parameters      = [{ name = "revision", value = var.gitops_revision }]

  # module.secrets_apps (2026-09-16, confirmed live on kind, soft -- NOT
  # module.wait_secrets_healthy): cert-manager-webhook-scaleway (this
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
  # Healthy) for reasons still unconfirmed, which fully serialized this
  # domain (and everything downstream of it) behind that unrelated
  # flakiness for this Job's own 30-minute budget. A soft create-order
  # dependency still closes the original race in practice (secrets-apps
  # starts syncing well before this Application is even created) without
  # hard-blocking on a convergence guarantee this domain doesn't actually
  # need.
  depends_on = [
    helm_release.argocd,
    module.wait_crds_healthy,
    module.secrets_apps,
  ]
}

module "wait_networking_controllers_healthy" {
  source = "../modules/wait-argocd-apps-healthy"

  job_name             = "wait-networking-controllers-healthy"
  app_names            = [module.networking_controllers_apps.application_name]
  service_account_name = module.wait_rbac.service_account_name
  revision_trigger     = module.networking_controllers_apps.helm_release_revision

  depends_on = [module.networking_controllers_apps, module.wait_rbac]
}

module "networking_resources_apps" {
  source = "../modules/argocd-platform-domain"

  name            = "networking-resources-apps"
  source_repo     = local.platform_apps_source_repo
  target_revision = var.infra_revision
  source_path     = local.platform_apps_path
  value_files     = ["values-networking-resources-kind.yaml"]
  parameters = [
    { name = "revision", value = var.gitops_revision },
    # Forced to a self-signed ClusterIssuer for this tier (gitops repo's
    # services/platform/gateway/config, clusterissuer-selfsigned.yaml
    # template) -- structurally prevents cert-manager from ever triggering
    # a real DNS01 challenge through cert-manager-webhook-scaleway,
    # regardless of the real Scaleway DNS credentials that domain's
    # ExternalSecret resolves to (see main.tf's header comment). NOT
    # letsencrypt-prod/-staging.
    { name = "activeClusterIssuer", value = "selfsigned" },
    { name = "hostSuffix", value = "" },
  ]

  depends_on = [
    helm_release.argocd,
    module.wait_networking_controllers_healthy,
    module.wait_secrets_healthy,
    module.wait_backups_healthy,
  ]
}

# ── Tier 1: dex/argocd-config/grafana ────────────────────────────────────────
module "dex_apps" {
  source = "../modules/argocd-platform-domain"

  name            = "dex-apps"
  source_repo     = local.platform_apps_source_repo
  target_revision = var.infra_revision
  source_path     = local.platform_apps_path
  value_files     = ["values-dex.yaml"]
  parameters      = [{ name = "revision", value = var.gitops_revision }]

  depends_on = [
    helm_release.argocd,
    module.secrets_apps,
  ]
}

module "wait_dex_healthy" {
  source = "../modules/wait-argocd-apps-healthy"

  job_name             = "wait-dex-healthy"
  app_names            = [module.dex_apps.application_name]
  service_account_name = module.wait_rbac.service_account_name
  revision_trigger     = module.dex_apps.helm_release_revision

  depends_on = [module.dex_apps, module.wait_rbac]
}

module "argocd_config_apps" {
  source = "../modules/argocd-platform-domain"

  name            = "argocd-config-apps"
  source_repo     = local.platform_apps_source_repo
  target_revision = var.infra_revision
  source_path     = local.platform_apps_path
  value_files     = ["values-argocd-config.yaml"]
  parameters      = [{ name = "revision", value = var.gitops_revision }]

  depends_on = [
    helm_release.argocd,
    module.wait_secrets_healthy,
  ]
}

module "grafana_apps" {
  source = "../modules/argocd-platform-domain"

  name            = "grafana-apps"
  source_repo     = local.platform_apps_source_repo
  target_revision = var.infra_revision
  source_path     = local.platform_apps_path
  value_files     = ["values-grafana.yaml"]
  parameters = [
    { name = "revision", value = var.gitops_revision },
    { name = "letsEncryptStaging", value = "false" },
  ]

  depends_on = [
    helm_release.argocd,
    module.secrets_apps,
    module.wait_backups_healthy,
  ]
}

# ── Tier 2: argo-workflows ────────────────────────────────────────────────────
#
# No module.wait_grafana_healthy here, unlike 10-cluster/scaleway -- that
# gate only exists there to feed crossplane-apps (dropped in this tier, see
# this file's own header comment), so creating one here would be dead
# infrastructure with no consumer.
module "argo_workflows_apps" {
  source = "../modules/argocd-platform-domain"

  name            = "argo-workflows-apps"
  source_repo     = local.platform_apps_source_repo
  target_revision = var.infra_revision
  source_path     = local.platform_apps_path
  value_files     = ["values-argo-workflows.yaml"]
  parameters      = [{ name = "revision", value = var.gitops_revision }]

  depends_on = [
    helm_release.argocd,
    module.secrets_apps,
    module.wait_dex_healthy,
  ]
}

# The "is everything actually healthy" check -- same reasoning as
# 10-cluster/scaleway/argocd.tf's module.wait_all_domains_healthy, trimmed
# to this tier's own (smaller) domain list (no wireguard-apps/crossplane-apps
# -- see this file's own header comment for why).
module "wait_all_domains_healthy" {
  source = "../modules/wait-argocd-apps-healthy"

  job_name = "wait-all-domains-healthy"
  app_names = [
    module.crds_apps.application_name,
    module.secrets_apps.application_name,
    module.backups_apps.application_name,
    module.networking_controllers_apps.application_name,
    module.networking_resources_apps.application_name,
    module.dex_apps.application_name,
    module.argocd_config_apps.application_name,
    module.grafana_apps.application_name,
    module.argo_workflows_apps.application_name,
  ]
  service_account_name = module.wait_rbac.service_account_name

  revision_trigger = join(",", [
    module.crds_apps.helm_release_revision,
    module.secrets_apps.helm_release_revision,
    module.backups_apps.helm_release_revision,
    module.networking_controllers_apps.helm_release_revision,
    module.networking_resources_apps.helm_release_revision,
    module.dex_apps.helm_release_revision,
    module.argocd_config_apps.helm_release_revision,
    module.grafana_apps.helm_release_revision,
    module.argo_workflows_apps.helm_release_revision,
  ])

  depends_on = [
    module.crds_apps,
    module.secrets_apps,
    module.backups_apps,
    module.networking_controllers_apps,
    module.networking_resources_apps,
    module.dex_apps,
    module.argocd_config_apps,
    module.grafana_apps,
    module.argo_workflows_apps,
    module.wait_rbac,
  ]
}
