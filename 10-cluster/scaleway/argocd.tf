# infra#113: the platform-apps DAG (which Applications, in what order,
# gated by what) is now expressed through shared modules
# (10-cluster/modules/argocd-platform-domain, wait-argocd-apps-healthy,
# argocd-wait-rbac, argocd-base-values), the SAME ones
# 10-cluster/kind/argocd.tf uses -- not hand-duplicated Terraform. This file
# now holds only what's genuinely environment-specific to the real Scaleway
# homelab: the full domain list (monitoring-apps/wireguard-apps/
# crossplane-apps included, dropped in the kind tier), the `bootstrap`
# Application pulling gitops's own app-of-apps, ArgoCD's real OIDC/Dex
# login + public URL + RBAC policy, and the revision-existence-probing
# DevX trick. See 10-cluster/scaleway/platform-apps/README.md for the
# platform-wide DAG this wiring encodes, and
# 10-cluster/modules/argocd-platform-domain/main.tf for why the per-domain
# module deliberately does NOT also own its wait gate (soft vs. hard
# cross-domain dependencies would otherwise collapse into always-hard).

locals {
  # Both ArgoCD Applications' own `targetRevision` (evaluated by ArgoCD's
  # repo-server) and every provider-opentofu Workspace's git module `?ref=`
  # (infra#76's gitRef, now threaded through crossplane-config) assume the
  # branch named by var.gitops_revision/var.infra_revision actually exists
  # on its repo -- true for the "override on your own branch, test
  # end-to-end, never merge that change" DevX trick IF you remember to
  # reset it before merging, but ArgoCD has NO built-in fallback: an
  # unresolvable targetRevision just sits in ComparisonError forever, no
  # automatic revert to a previous/default revision. Resolved here instead,
  # at apply time (before ArgoCD ever sees a revision) -- see the
  # data.external "*_revision_exists" pair + effective_*_revision locals
  # below.
  gitops_source_repo        = "https://github.com/IntegratedDynamic/gitops.git"
  platform_apps_source_repo = "https://github.com/IntegratedDynamic/infrastructure.git"
  platform_apps_path        = "10-cluster/scaleway/platform-apps"
}

# `--heads`-only existence probe per repo/revision -- always exits 0 and
# reports {"exists": "true"|"false"} in its own JSON, never a hard
# data-source failure on a missing branch (unlike e.g. `data "http"` against
# GitHub's API, which errors the whole apply on a 404). Only run when the
# var isn't already "main" (count) -- the common case makes zero network
# calls; effective_*_revision below treats a skipped check as "exists" so
# the result still resolves to "main" either way when count = 0.
data "external" "gitops_revision_exists" {
  count = var.gitops_revision != "main" ? 1 : 0

  program = ["sh", "-c", <<-EOT
    if git ls-remote --exit-code --heads ${local.gitops_source_repo} "${var.gitops_revision}" >/dev/null 2>&1; then
      echo '{"exists": "true"}'
    else
      echo '{"exists": "false"}'
    fi
  EOT
  ]
}

data "external" "infra_revision_exists" {
  count = var.infra_revision != "main" ? 1 : 0

  program = ["sh", "-c", <<-EOT
    if git ls-remote --exit-code --heads ${local.platform_apps_source_repo} "${var.infra_revision}" >/dev/null 2>&1; then
      echo '{"exists": "true"}'
    else
      echo '{"exists": "false"}'
    fi
  EOT
  ]
}

locals {
  # The revision every targetRevision/gitRef below actually uses -- var.
  # gitops_revision/var.infra_revision verbatim when that branch exists
  # upstream (or when it's already "main", never probed), "main" otherwise.
  # `--heads` only checks branches, matching these vars' documented
  # "override on your own branch" purpose -- a tag or bare commit SHA would
  # (incorrectly) fall back to "main" too, but neither is a supported value
  # for either variable today.
  effective_gitops_revision = try(data.external.gitops_revision_exists[0].result.exists, "true") == "true" ? var.gitops_revision : "main"
  effective_infra_revision  = try(data.external.infra_revision_exists[0].result.exists, "true") == "true" ? var.infra_revision : "main"

  # var.letsencrypt_staging (see that variable's own comment): which
  # ClusterIssuer gateway-config's Gateway actually uses. Threaded into
  # networking_resources_apps' own Application parameters below (same
  # pattern values-crossplane.yaml's gitRefParam/infraRevision already
  # establishes), which platform-apps/templates/apps.yaml then injects into
  # gateway-config's own child Application via its activeClusterIssuerParam
  # flag (values-networking-resources.yaml).
  active_cluster_issuer = var.letsencrypt_staging ? "letsencrypt-staging" : "letsencrypt-prod"

  # var.env_suffix (see that variable's own comment) -- threaded into
  # networking_resources_apps' own Application parameters below as
  # `hostSuffix`, same pattern as active_cluster_issuer above. Empty stays
  # empty (main's own workspace, zero behavior change); a non-empty value
  # gets the leading "-" prepended once here so every *-gateway chart just
  # appends this local verbatim instead of each reimplementing the
  # empty-vs-non-empty branch.
  host_suffix = var.env_suffix != "" ? "-${var.env_suffix}" : ""
}

module "argocd_base_values" {
  source = "../modules/argocd-base-values"

  # Bumped 1000 -> 1500 2026-08-20: confirmed live that 1000Mi + GOMEMLIMIT
  # alone wasn't enough headroom for a full from-scratch tree resync (all
  # ~30 Applications across every wave at once, not just the steady-state
  # reconciliation loop the earlier 1000Mi figure was sized from).
  argocd_controller_memory_limit_mib = 1500
}

resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "9.4.17"

  # Fail fast (under the 5m default) if ArgoCD doesn't come up. Transient blips
  # (e.g. quay.io 502s) are absorbed by retrying the apply (see mise scaleway-up).
  timeout = 240

  depends_on = [scaleway_k8s_pool.default]

  values = [
    module.argocd_base_values.values,
    <<-EOF
    configs:
      params:
        # JSON, not the default logfmt-ish text -- Alloy (gitops repo,
        # services/platform/monitoring/alloy-chart) already tails every
        # pod's logs into Loki cluster-wide from wave 4 on, well before
        # Grafana's own UI is reachable (wave 5+), so ArgoCD's own state is
        # already being captured from early boot -- this just makes what's
        # captured reliably field-parseable once actually queried, instead
        # of Loki's logfmt heuristic guessing at a text format that isn't
        # guaranteed stable.
        controller.log.format: json
        server.log.format: json
        reposerver.log.format: json
        applicationsetcontroller.log.format: json

      cm:
        url: https://argocd.scalepack.fr

        # Cuts cluster-cache memory, not just the controller's own
        # footprint -- by default the controller watches every API
        # resource kind in the cluster for live-state diffing, regardless
        # of whether any Application actually manages instances of that
        # kind. events.k8s.io/*, metrics.k8s.io/* and
        # coordination.k8s.io/Lease are already excluded by Argo CD itself
        # unconditionally; these two rules add the next-highest-churn
        # kinds this cluster actually has plenty of and no Application
        # ever references:
        #  - discovery.k8s.io/EndpointSlice (+ legacy v1/Endpoints): one
        #    object (Endpoints) or more (EndpointSlice) per Service,
        #    rewritten on every pod readiness flip.
        #  - cilium.io/* (CiliumEndpoint, CiliumIdentity, CiliumNode, ...):
        #    Cilium is the Kapsule cluster's CNI (main.tf's
        #    scaleway_k8s_cluster.this, cni = "cilium"), provisioned by
        #    Scaleway itself, not an ArgoCD Application.
        # https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/#resource-exclusioninclusion
        resource.exclusions: |
          - apiGroups:
            - discovery.k8s.io
            kinds:
            - EndpointSlice
          - apiGroups:
            - ""
            kinds:
            - Endpoints
          - apiGroups:
            - cilium.io
            kinds:
            - "*"

        # Local admin login is redundant now that OIDC via Dex is working —
        # one login path, no separate password to rotate/leak.
        admin.enabled: "false"

        # Native OIDC against our own shared Dex (platform/scaleway/dex.yml in
        # the gitops repo, staticClients.argocd) instead of the chart's built-in
        # Dex (disabled by module.argocd_base_values) — one Dex instance for
        # the whole platform, one place the GitHub org/team restriction is
        # defined.
        oidc.config: |
          name: Dex
          issuer: https://auth.scalepack.fr
          clientID: argocd
          # Resolved from the argocd-oidc-client-secret Secret (gitops repo:
          # apps/argocd-config), not the default argocd-secret — that secret
          # carries the app.kubernetes.io/part-of: argocd label ArgoCD requires
          # for custom secret references.
          clientSecret: $argocd-oidc-client-secret:oidc.clientSecret
          # `argocd login --sso` talks to Dex directly (PKCE, no client
          # secret) rather than through argocd-server's own /auth/callback —
          # it can't use the confidential `argocd` client above, so it gets
          # its own public client (gitops repo: platform/scaleway/dex.yml,
          # staticClients.argocd-cli).
          cliClientID: argocd-cli
          requestedScopes:
            - openid
            - profile
            - email
            - groups
    %{if var.letsencrypt_staging~}
          # var.letsencrypt_staging (see that variable's own comment): ArgoCD's
          # native per-provider CA override for OIDC discovery/token calls to
          # https://auth.scalepack.fr -- no pod/volume/init-container change
          # needed, and doesn't touch trust for any other legitimate HTTPS call
          # this pod makes (e.g. GitHub for git repos).
          # https://argo-cd.readthedocs.io/en/stable/operator-manual/user-management/#configuring-a-custom-root-ca-certificate-for-communicating-with-the-oidc-provider
          rootCA: |
            ${indent(8, trimspace(local.letsencrypt_staging_ca_pem))}
    %{endif~}

      rbac:
        policy.csv: |
          g, IntegratedDynamic:Admin, role:admin
        policy.default: role:readonly

    # Sized from `kubectl top pods -n argocd` on the live cluster
    # (2026-08-11, two samples ~15min apart), not from chart-doc guesses.
    # controller is the standout: it watches the live state of every
    # resource this whole GitOps repo manages, so its memory scales with
    # total tracked resource count, not just "idle controller usage".
    controller:
      # Small node pool -- system-cluster-critical (built into every
      # Kubernetes cluster, usable outside kube-system unlike
      # system-node-critical) protects this pod specifically from the
      # kubelet's own node-memory-pressure eviction (confirmed live
      # 2026-08-20: this pod was evicted at 91% of a node's memory even
      # while under its own container limit -- a different mechanism than
      # the cgroup OOM kill GOMEMLIMIT addresses) and gives it scheduling
      # priority over everything else in this namespace.
      priorityClassName: system-cluster-critical
      metrics:
        enabled: true
        serviceMonitor:
          enabled: true
          additionalLabels:
            release: kube-prometheus-stack

    repoServer:
      metrics:
        enabled: true
        serviceMonitor:
          enabled: true
          additionalLabels:
            release: kube-prometheus-stack

    server:
      metrics:
        enabled: true
        serviceMonitor:
          enabled: true
          additionalLabels:
            release: kube-prometheus-stack
      # reloader (gitops repo's services/platform/reloader/chart, secrets-apps
      # wave 0) auto-detects a workload's own volume/env references to a
      # changed ConfigMap/Secret -- but argocd-server never mounts
      # argocd-oidc-client-secret that way, it's only ever read via argocd-cm's
      # `$argocd-oidc-client-secret:oidc.clientSecret` string substitution,
      # invisible to that scan. This explicit annotation is the fallback for
      # exactly that case: any future rotation of that secret now gets a free
      # rolling-restart instead of relying solely on a one-shot PostSync hook.
      deploymentAnnotations:
        secret.reloader.stakater.com/reload: "argocd-oidc-client-secret"

    applicationSet:
      # Beta feature (argo-helm/argo-cd chart): without this flag, the
      # argocd.argoproj.io/sync-wave annotation on Applications generated by an
      # ApplicationSet does nothing — each generated Application is created and
      # auto-synced independently, with no ordering across them. Needed by
      # gitops's services-app-scaleway ApplicationSet (bootstrap/templates/scaleway.yaml),
      # whose RollingSync strategy groups Velero/external-dns/Dex/Grafana after
      # the OpenBao-backed Secrets their own sibling -init/-config apps produce.
      extraArgs:
        - --enable-progressive-syncs

      metrics:
        enabled: true
        serviceMonitor:
          enabled: true
          additionalLabels:
            release: kube-prometheus-stack

      resources:
        requests:
          cpu: 10m
          memory: 64Mi
        limits:
          cpu: 100m
          memory: 128Mi

    notifications:
      resources:
        requests:
          cpu: 10m
          memory: 32Mi
        limits:
          cpu: 50m
          memory: 64Mi
    EOF
  ]
}

module "wait_rbac" {
  source = "../modules/argocd-wait-rbac"

  # Confirmed live (2026-08-25): without an explicit depends_on, nothing
  # ordered this RBAC after anything more than scaleway_k8s_cluster.this
  # itself (the only hard dependency the kubernetes/helm provider configs
  # create) -- Terraform fired it ~6s after the cluster control plane
  # finished, in parallel with scaleway_k8s_pool.default (which took several
  # more minutes), and hit DNS resolution failures on the cluster's own API
  # hostname twice in a row at exactly this point. Depending on
  # helm_release.argocd directly covers both "pool is ready" (it has its
  # own depends_on) and "the argocd namespace these RBAC objects live in
  # exists" (create_namespace = true) in one dependency.
  depends_on = [helm_release.argocd]
}

# ── Tier -1: crds-apps, every CRD-only chart across the whole platform ──────
#
# See 10-cluster/scaleway/platform-apps/README.md's "One CRDs domain for the
# whole platform" section for the full history/rationale. depends_on ONLY
# helm_release.argocd: CRD registration needs nothing but the API server
# reachable, no Secret, no other domain.
module "crds_apps" {
  source = "../modules/argocd-platform-domain"

  name            = "crds-apps"
  source_repo     = local.platform_apps_source_repo
  target_revision = local.effective_infra_revision
  source_path     = local.platform_apps_path
  value_files     = ["values-crds.yaml"]
  parameters      = [{ name = "revision", value = local.effective_gitops_revision }]

  depends_on = [helm_release.argocd]
}

# Real Terraform-enforced prerequisite of every Tier-0 domain -- ArgoCD has
# no native way to say "don't even create Application X until Application Y
# is genuinely Healthy" across independent top-level Applications.
module "wait_crds_healthy" {
  source = "../modules/wait-argocd-apps-healthy"

  job_name             = "wait-crds-healthy"
  app_names            = [module.crds_apps.application_name]
  service_account_name = module.wait_rbac.service_account_name
  revision_trigger     = module.crds_apps.helm_release_revision

  depends_on = [module.crds_apps, module.wait_rbac]
}

# openbao/openbao-init (wave 0), external-secrets (wave 0), secrets-sync
# (wave 1), every product's ExternalSecret (wave 2) -- see
# platform-apps/README.md's "Consolidating wait-hops into intra-Application
# waves" for the full merge history. No module.wait_crds_healthy: external-
# secrets manages its own CRDs, and OpenBao needs no CRD at all -- starts in
# parallel with crds-apps.
module "secrets_apps" {
  source = "../modules/argocd-platform-domain"

  name            = "secrets-apps"
  source_repo     = local.platform_apps_source_repo
  target_revision = local.effective_infra_revision
  source_path     = local.platform_apps_path
  value_files     = ["values-secrets.yaml"]
  parameters      = [{ name = "revision", value = local.effective_gitops_revision }]

  # scaleway_s3_credentials/openbao_unseal_aws: this Application manages the
  # openbao child Application and writes into the openbao namespace, so it
  # must still be guaranteed to finish its own cascade-delete before
  # kubernetes_namespace.openbao's destroy (confirmed live 2026-08-25:
  # ArgoCD's openbao Application was mid-retry writing into that namespace
  # while Terraform deleted it directly).
  depends_on = [
    helm_release.argocd,
    kubernetes_secret.scaleway_s3_credentials,
    kubernetes_secret.openbao_unseal_aws,
  ]
}

# The ONE surviving Terraform gate for the whole secrets tree -- see
# platform-apps/README.md for exactly what this transitively covers
# (OpenBao Kubernetes-auth readiness, external-secrets CRDs Established,
# ESO's webhook serving).
module "wait_secrets_healthy" {
  source = "../modules/wait-argocd-apps-healthy"

  job_name             = "wait-secrets-healthy"
  app_names            = [module.secrets_apps.application_name]
  service_account_name = module.wait_rbac.service_account_name
  revision_trigger     = module.secrets_apps.helm_release_revision

  depends_on = [module.secrets_apps, module.wait_rbac]
}

# No ESO ExternalSecret in this domain (thanos/loki/tempo credentials are
# Terraform-originated Secrets, see platform-apps/README.md's "secret-
# delivery pattern") -- no ordering dependency on secrets-apps needed.
module "monitoring_apps" {
  source = "../modules/argocd-platform-domain"

  name            = "monitoring-apps"
  source_repo     = local.platform_apps_source_repo
  target_revision = local.effective_infra_revision
  source_path     = local.platform_apps_path
  value_files     = ["values-monitoring.yaml"]
  parameters      = [{ name = "revision", value = local.effective_gitops_revision }]

  depends_on = [
    helm_release.argocd,
    module.wait_crds_healthy,
    kubernetes_secret.thanos_objstore_config,
    kubernetes_secret.loki_s3_credentials,
    kubernetes_secret.tempo_s3_credentials,
  ]
}

# Since the 2026-08-27 merge (values-backups.yaml) this domain holds velero
# (wave 0) AND its two restore hooks cert-restore/grafana-restore (wave 1).
# null_resource.velero_namespace_predelete_cleanup stays listed here for the
# DESTROY direction: "A depends_on B" means A destroys before B, so listing
# it here makes this release destroy (and Velero's controller die) BEFORE
# that cleanup's local-exec runs -- see that resource's own comment in
# main.tf for the two earlier, wrong ordering attempts.
module "backups_apps" {
  source = "../modules/argocd-platform-domain"

  name            = "backups-apps"
  source_repo     = local.platform_apps_source_repo
  target_revision = local.effective_infra_revision
  source_path     = local.platform_apps_path
  value_files     = ["values-backups.yaml"]
  parameters      = [{ name = "revision", value = local.effective_gitops_revision }]

  depends_on = [
    helm_release.argocd,
    kubernetes_secret.velero_scaleway_credentials,
    null_resource.velero_namespace_predelete_cleanup,
  ]
}

# The ONE surviving Terraform gate for the whole backups tree -- covers both
# Velero being genuinely healthy AND the restore Jobs having finished (or
# explicitly skipped, fail-open).
module "wait_backups_healthy" {
  source = "../modules/wait-argocd-apps-healthy"

  job_name             = "wait-backups-healthy"
  app_names            = [module.backups_apps.application_name]
  service_account_name = module.wait_rbac.service_account_name
  revision_trigger     = module.backups_apps.helm_release_revision

  depends_on = [module.backups_apps, module.wait_rbac]
}

# Split out of the old combined networking-apps (infra#100) -- envoy-gateway/
# cert-manager consume nothing but crds-apps being Established, not any
# ExternalSecret, so unlike networking-resources-apps below this domain has
# no dependency on secrets-apps at all.
module "networking_controllers_apps" {
  source = "../modules/argocd-platform-domain"

  name            = "networking-controllers-apps"
  source_repo     = local.platform_apps_source_repo
  target_revision = local.effective_infra_revision
  source_path     = local.platform_apps_path
  value_files     = ["values-networking-controllers.yaml"]
  parameters      = [{ name = "revision", value = local.effective_gitops_revision }]

  depends_on = [
    helm_release.argocd,
    module.wait_crds_healthy,
  ]
}

# Real Terraform-enforced prerequisite of networking-resources-apps below --
# gateway-config's ClusterIssuers are cert-manager.io-typed and its sync
# fails outright (no self-heal) if cert-manager's own webhook isn't
# registered and serving yet, a genuinely stronger requirement than "the CRD
# exists" (crds-apps' own gate).
module "wait_networking_controllers_healthy" {
  source = "../modules/wait-argocd-apps-healthy"

  job_name             = "wait-networking-controllers-healthy"
  app_names            = [module.networking_controllers_apps.application_name]
  service_account_name = module.wait_rbac.service_account_name
  revision_trigger     = module.networking_controllers_apps.helm_release_revision

  depends_on = [module.networking_controllers_apps, module.wait_rbac]
}

# Since the 2026-08-27 merge (values-networking-resources.yaml) this single
# Application holds gateway-config/external-dns (wave 0) AND every product's
# `*-gateway` HTTPRoute chart (wave 1). Networking CONTROLLERS deliberately
# stay a SEPARATE Application (module.networking_controllers_apps) -- NOT an
# earlier wave here: Terraform can only gate an Application's creation, not
# pause mid-sync between two of its own waves, so folding the controllers in
# would force them to also wait for Secrets+Backups below for no reason.
#
# Gates:
#  - module.wait_networking_controllers_healthy (hard): gateway-config's
#    ClusterIssuers fail outright at the API level if cert-manager's webhook
#    isn't registered and serving yet.
#  - module.wait_secrets_healthy (hard): gateway-config/external-dns consume
#    cert-manager-webhook-secret/external-dns-secret, and this is the single
#    check covering every ExternalSecret's webhook-serving readiness (plus
#    the externalsecret-cleanup finalizer's destroy-ordering).
#  - module.wait_backups_healthy: gateway-config's wildcard TLS Secret
#    restore is wave 1 of backups-apps.
module "networking_resources_apps" {
  source = "../modules/argocd-platform-domain"

  name            = "networking-resources-apps"
  source_repo     = local.platform_apps_source_repo
  target_revision = local.effective_infra_revision
  source_path     = local.platform_apps_path
  value_files     = ["values-networking-resources.yaml"]
  parameters = [
    { name = "revision", value = local.effective_gitops_revision },
    # var.letsencrypt_staging (see local.active_cluster_issuer above) --
    # picked up by gateway-config's own entry in
    # values-networking-resources.yaml (activeClusterIssuerParam: true).
    { name = "activeClusterIssuer", value = local.active_cluster_issuer },
    # var.env_suffix / local.host_suffix -- picked up by every *-gateway
    # chart in this Application (hostSuffixParam: true on each entry in
    # values-networking-resources.yaml), NOT gateway-config itself.
    { name = "hostSuffix", value = local.host_suffix },
  ]

  depends_on = [
    helm_release.argocd,
    module.wait_networking_controllers_healthy,
    module.wait_secrets_healthy,
    module.wait_backups_healthy,
  ]
}

# wireguard-secret lives in secrets-apps' wave 2 -- wireguard-config just
# consumes the Secret it materializes, so this is a soft create-order +
# destroy-ordering dependency (also protects that ExternalSecret's
# externalsecret-cleanup finalizer). No CRD consumed either -- the same
# "don't pay for a dependency you don't have" reasoning that keeps OpenBao
# off crds-apps.
module "wireguard_apps" {
  source = "../modules/argocd-platform-domain"

  name            = "wireguard-apps"
  source_repo     = local.platform_apps_source_repo
  target_revision = local.effective_infra_revision
  source_path     = local.platform_apps_path
  value_files     = ["values-wireguard.yaml"]
  parameters      = [{ name = "revision", value = local.effective_gitops_revision }]

  depends_on = [
    helm_release.argocd,
    module.secrets_apps,
  ]
}

# ── Tier 1: dex/argocd-config/grafana, extracted from gitops repo (infra#84 follow-up) ───
#
# Each of these three domains shares the identical dependency profile: a
# soft dependency on module.secrets_apps -- but each stays its OWN domain
# rather than one bundled Application, since argo-workflows-apps (Tier 2,
# below) needs to health-wait on dex specifically, not a bundle diluted by
# argocd-config/grafana's unrelated health.
module "dex_apps" {
  source = "../modules/argocd-platform-domain"

  name            = "dex-apps"
  source_repo     = local.platform_apps_source_repo
  target_revision = local.effective_infra_revision
  source_path     = local.platform_apps_path
  value_files     = ["values-dex.yaml"]
  parameters      = [{ name = "revision", value = local.effective_gitops_revision }]

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

# module.wait_secrets_healthy (hard, promoted from the soft "depends_on
# secrets_apps" every other Tier-1-soft domain keeps):
# services/platform/argocd-config/config's PostSync restart-hook Job
# (argocd-config-restart-server) bounces argocd-server so it picks up
# argocd-oidc-client-secret's now-resolved $-reference (ArgoCD never
# re-reads a $secretName:key substitution live -- only a real pod restart
# clears it). Confirmed live (2026-09-14): a soft dependency only waits for
# Terraform's own `helm install` to return, not for secrets-apps to actually
# sync -- the hook fired against a not-yet-existing secret and every SSO
# login failed for the rest of that cluster's life. dex-apps/wireguard-apps
# can stay soft (long-running Deployments that keep re-reading the mounted
# Secret / get bounced by reloader on change); a one-shot PostSync hook has
# no such self-healing.
module "argocd_config_apps" {
  source = "../modules/argocd-platform-domain"

  name            = "argocd-config-apps"
  source_repo     = local.platform_apps_source_repo
  target_revision = local.effective_infra_revision
  source_path     = local.platform_apps_path
  value_files     = ["values-argocd-config.yaml"]
  parameters      = [{ name = "revision", value = local.effective_gitops_revision }]

  depends_on = [
    helm_release.argocd,
    module.wait_secrets_healthy,
  ]
}

module "grafana_apps" {
  source = "../modules/argocd-platform-domain"

  name            = "grafana-apps"
  source_repo     = local.platform_apps_source_repo
  target_revision = local.effective_infra_revision
  source_path     = local.platform_apps_path
  value_files     = ["values-grafana.yaml"]
  parameters = [
    { name = "revision", value = local.effective_gitops_revision },
    { name = "letsEncryptStaging", value = tostring(var.letsencrypt_staging) },
  ]

  depends_on = [
    helm_release.argocd,
    module.secrets_apps,
    module.wait_backups_healthy,
    # Referencing a count-based resource directly (no index/splat) depends
    # on ALL of its instances -- zero of them when var.letsencrypt_staging
    # is false, so this is a no-op in that case, not an error.
    kubernetes_config_map.letsencrypt_staging_ca_monitoring,
  ]
}

# ── Tier 2: argo-workflows, extracted from gitops repo (infra#84 follow-up) ───
#
# argo-workflows/chart eager-dials Dex's OIDC issuer at pod startup and
# crash-loops if Dex isn't reachable -- a real hard dependency, unlike ESO's
# self-heal tolerance.
module "argo_workflows_apps" {
  source = "../modules/argocd-platform-domain"

  name            = "argo-workflows-apps"
  source_repo     = local.platform_apps_source_repo
  target_revision = local.effective_infra_revision
  source_path     = local.platform_apps_path
  value_files     = ["values-argo-workflows.yaml"]
  parameters      = [{ name = "revision", value = local.effective_gitops_revision }]

  depends_on = [
    helm_release.argocd,
    module.secrets_apps,
    module.wait_dex_healthy,
  ]
}

# ── Tier 3: crossplane, extracted from gitops repo (infra#84 follow-up; issue #101) ───
#
# Crossplane core + upbound/provider-opentofu -- the unattended `tofu apply`
# loop for 11-secrets/openbao/managed and 12-monitoring/grafana/managed
# (issue #101). Neither gate below is a hard blocker for the Workspaces to
# eventually converge -- provider-opentofu retries on its own backoff -- but
# starting crossplane-apps before either tool is up would just burn
# reconcile attempts.
module "wait_grafana_healthy" {
  source = "../modules/wait-argocd-apps-healthy"

  job_name             = "wait-grafana-healthy"
  app_names            = [module.grafana_apps.application_name]
  service_account_name = module.wait_rbac.service_account_name
  revision_trigger     = module.grafana_apps.helm_release_revision

  depends_on = [module.grafana_apps, module.wait_rbac]
}

module "crossplane_apps" {
  source = "../modules/argocd-platform-domain"

  name            = "crossplane-apps"
  source_repo     = local.platform_apps_source_repo
  target_revision = local.effective_infra_revision
  source_path     = local.platform_apps_path
  value_files     = ["values-crossplane.yaml"]
  parameters = [
    { name = "revision", value = local.effective_gitops_revision },
    # infra#76: threads THIS repo's own revision through so
    # crossplane-config's gitRefParam (values-crossplane.yaml) overrides its
    # chart's `gitRef: main` default -- every Workspace's git module `?ref=`
    # then follows the infra branch under test.
    { name = "infraRevision", value = local.effective_infra_revision },
  ]

  depends_on = [
    helm_release.argocd,
    module.wait_secrets_healthy,
    module.wait_grafana_healthy,
  ]
}

# `bootstrap` -- gitops repo's own app-of-apps (now just `demo`, every other
# domain migrated into the platform-apps domains above). Fits the SAME
# argocd-platform-domain shape (finalizers/project/destination/syncPolicy)
# even though its source is the gitops repo, not this one, and it's driven
# entirely by parameters (no valueFiles).
module "bootstrap_app" {
  source = "../modules/argocd-platform-domain"

  name            = "bootstrap"
  source_repo     = local.gitops_source_repo
  target_revision = local.effective_gitops_revision
  source_path     = "bootstrap"
  parameters = [
    { name = "env", value = "scaleway" },
    { name = "revision", value = local.effective_gitops_revision },
  ]

  # module.wait_all_domains_healthy no longer gates this (2026-09-16 --
  # moved to the very end of this file, made optional via
  # var.wait_all_domains_healthy). bootstrap's own Application doesn't
  # actually read anything from the other platform domains, so there was no
  # correctness reason for its creation to wait on all of them -- crossplane-
  # apps included -- being Healthy first. See module.wait_all_domains_healthy's
  # own comment for the full "why" this moved.
  depends_on = [helm_release.argocd]
}

# Confirmed live (2026-08-25): without this, `terraform apply` reports
# success the moment module.bootstrap_app creates the bootstrap Application
# *object* -- Helm's own --wait readiness checks understand built-in
# Kubernetes kinds, not ArgoCD's Application CRD health semantics, so it
# doesn't actually wait for bootstrap's own sync to finish. A `terraform
# destroy` issued right after such an apply hit bootstrap still mid-forward-
# sync, and only started actually cascade-deleting once that finished --
# several extra minutes of confusion a genuine wait here avoids.
module "wait_bootstrap_healthy" {
  source = "../modules/wait-argocd-apps-healthy"

  job_name             = "wait-bootstrap-healthy"
  app_names            = [module.bootstrap_app.application_name]
  service_account_name = module.wait_rbac.service_account_name
  revision_trigger     = module.bootstrap_app.helm_release_revision

  depends_on = [module.bootstrap_app, module.wait_rbac]
}

# The Terraform-enforced "is EVERY platform domain actually healthy" check —
# ArgoCD has no native way to express "wait for these independent top-level
# Applications" (sync-wave doesn't cross Application boundaries). Moved to
# the very end of this file (2026-09-16, was originally right before
# module.bootstrap_app, gating its own Application creation on it) and made
# optional via var.wait_all_domains_healthy (see that variable's own
# comment). Now runs LAST, after bootstrap itself is confirmed healthy
# (module.wait_bootstrap_healthy above) -- a genuine "the whole platform,
# slow stuff included, is truly done converging" sanity check for main's own
# workspace, skippable for an ephemeral one that just wants the core
# platform up fast.
#
# app_names lists every top-level domain Application by name, not just the
# DAG's leaves: checking leaves alone would work, but listing everything
# explicitly is the same defensive, easy-to-audit style this check has
# always used.
module "wait_all_domains_healthy" {
  count = var.wait_all_domains_healthy ? 1 : 0

  source = "../modules/wait-argocd-apps-healthy"

  job_name = "wait-all-domains-healthy"
  app_names = [
    module.crds_apps.application_name,
    module.secrets_apps.application_name,
    module.monitoring_apps.application_name,
    module.backups_apps.application_name,
    module.networking_controllers_apps.application_name,
    module.networking_resources_apps.application_name,
    module.wireguard_apps.application_name,
    module.dex_apps.application_name,
    module.argocd_config_apps.application_name,
    module.grafana_apps.application_name,
    module.argo_workflows_apps.application_name,
    module.crossplane_apps.application_name,
  ]
  service_account_name = module.wait_rbac.service_account_name

  # Forces a fresh Job whenever ANY watched domain is redeployed, and
  # supplies the implicit Terraform dependency on all of them.
  revision_trigger = join(",", [
    module.crds_apps.helm_release_revision,
    module.secrets_apps.helm_release_revision,
    module.monitoring_apps.helm_release_revision,
    module.backups_apps.helm_release_revision,
    module.networking_controllers_apps.helm_release_revision,
    module.networking_resources_apps.helm_release_revision,
    module.wireguard_apps.helm_release_revision,
    module.dex_apps.helm_release_revision,
    module.argocd_config_apps.helm_release_revision,
    module.grafana_apps.helm_release_revision,
    module.argo_workflows_apps.helm_release_revision,
    module.crossplane_apps.helm_release_revision,
  ])

  # module.wait_bootstrap_healthy added (2026-09-16, this module's move to
  # the end): this is now the LAST gate in the whole graph, so it depends on
  # bootstrap having already converged too, not just the platform-apps
  # domains.
  depends_on = [
    module.crds_apps,
    module.secrets_apps,
    module.monitoring_apps,
    module.backups_apps,
    module.networking_controllers_apps,
    module.networking_resources_apps,
    module.wireguard_apps,
    module.dex_apps,
    module.argocd_config_apps,
    module.grafana_apps,
    module.argo_workflows_apps,
    module.crossplane_apps,
    module.wait_rbac,
    module.wait_bootstrap_healthy,
  ]
}
