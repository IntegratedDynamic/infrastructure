# data "infisical_secrets" "this" {
#   env_slug     = "staging"
#   workspace_id = "7ecb6ed4-058a-46cd-ac9f-7e792469cf0f" // project ID
#   folder_path  = "/"
# }

locals {
  # GOMEMLIMIT mitigation for the argocd-application-controller OOMKilled
  # loop (confirmed live 2026-08-19/20, see controller.resources.limits.memory's
  # own comment below) -- makes the Go runtime trigger GC proactively before
  # the cgroup hard limit kills the process, instead of only reacting to the
  # kernel OOM killer. Per ArgoCD's own docs (80-90% of the container limit;
  # 85% splits the difference), computed from the limit instead of a second
  # hardcoded literal so the two can't drift out of the recommended ratio:
  # https://argo-cd.readthedocs.io/en/stable/operator-manual/high_availability/#mitigating-oomkilled-events-from-memory-spikes
  #
  # Bumped 1000 -> 1500 2026-08-20: confirmed live that 1000Mi + GOMEMLIMIT
  # alone wasn't enough headroom for a full from-scratch tree resync (all
  # ~30 Applications across every wave at once, not just the steady-state
  # reconciliation loop the earlier 1000Mi figure was sized from) --
  # GOMEMLIMIT only forces proactive GC, it can't shrink genuinely live
  # working-set below what a full resync actually needs to hold in memory
  # at once.
  argocd_controller_memory_limit_mib = 1500
  argocd_controller_gomemlimit_mib   = floor(local.argocd_controller_memory_limit_mib * 0.85)

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
  gitops_source_repo = "https://github.com/IntegratedDynamic/gitops.git"
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

  values = [<<EOF
configs:
  params:
    server.insecure: true
    # JSON, not the default logfmt-ish text -- Alloy (gitops repo,
    # services/platform/monitoring/alloy-chart) already tails every pod's
    # logs into Loki cluster-wide from wave 4 on, well before Grafana's own
    # UI is reachable (wave 5+), so ArgoCD's own state is already being
    # captured from early boot -- this just makes what's captured reliably
    # field-parseable once actually queried, instead of Loki's logfmt
    # heuristic guessing at a text format that isn't guaranteed stable.
    controller.log.format: json
    server.log.format: json
    reposerver.log.format: json
    applicationsetcontroller.log.format: json

  cm:
    url: https://argocd.scalepack.fr

    # Cuts cluster-cache memory, not just the controller's own footprint --
    # by default the controller watches every API resource kind in the
    # cluster for live-state diffing, regardless of whether any Application
    # actually manages instances of that kind. events.k8s.io/*,
    # metrics.k8s.io/* and coordination.k8s.io/Lease are already excluded
    # by Argo CD itself unconditionally; these two rules add the next-
    # highest-churn kinds this cluster actually has plenty of and no
    # Application ever references:
    #  - discovery.k8s.io/EndpointSlice (+ legacy v1/Endpoints): one
    #    object (Endpoints) or more (EndpointSlice) per Service, rewritten
    #    on every pod readiness flip -- never something an Application's
    #    health/sync depends on here.
    #  - cilium.io/* (CiliumEndpoint, CiliumIdentity, CiliumNode, ...):
    #    Cilium is the Kapsule cluster's CNI (main.tf's scaleway_k8s_cluster.this,
    #    cni = "cilium"), provisioned by Scaleway itself, not an ArgoCD
    #    Application -- no Application here ever references these, and
    #    Cilium creates one CiliumEndpoint per pod cluster-wide, the kind
    #    of per-pod-times-every-DaemonSet growth this exclusion is
    #    specifically meant to blunt.
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
    # one login path, no separate password to rotate/leak. To bring back
    # a break-glass fallback: set this back to "true" and restore the
    # set_sensitive block (removed in this commit — see git history) that
    # sets configs.secret.argocdServerAdminPassword from
    # var.argocd_admin_password_hash.
    admin.enabled: "false"

    # Without this, ArgoCD has no built-in health assessor for its own
    # `Application` CRD — a nested Application (bootstrap/values.yaml's
    # scalewayApps, gitops repo) is treated as "Healthy" the instant it's
    # created with no sync error, never actually reflecting whether its own
    # Helm release finished deploying. That silently degrades every
    # sync-wave boundary in bootstrap/templates/scaleway.yaml from "wait for
    # the previous wave to be ready" to "wait for the previous wave's
    # Application objects to exist" — confirmed live 2026-08-12: wave 5
    # (cert-manager) started ~14s after wave 4 (envoy-gateway) was created,
    # while envoy-gateway's own chart took ~90s to actually deploy, causing
    # a self-healing but real crash-loop race. This teaches ArgoCD to
    # recurse into the child Application's own `.status.health` instead of
    # defaulting to healthy-on-creation — the standard fix for this well-known
    # "app of apps" gotcha. Health assessment of the argoproj.io/Application
    # CRD was removed in ArgoCD 1.8; this is the documented restoration
    # snippet:
    # https://argo-cd.readthedocs.io/en/stable/operator-manual/health/
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

    # Native OIDC against our own shared Dex (platform/scaleway/dex.yml in
    # the gitops repo, staticClients.argocd) instead of the chart's built-in
    # Dex (disabled below) — one Dex instance for the whole platform, one
    # place the GitHub org/team restriction is defined.
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
      # needed (unlike a generic SSL_CERT_FILE override), and doesn't touch
      # trust for any other legitimate HTTPS call this pod makes (e.g.
      # GitHub for git repos). Same mechanism this repo used historically
      # for the same purpose (2026-07-25, commit 98f87ce, reverted once
      # back on letsencrypt-prod) -- reused here rather than the heavier
      # merge-CA-bundle init-container approach main.tf's own comment on
      # this flag explains was tried and reverted for OpenBao/ArgoCD.
      # https://argo-cd.readthedocs.io/en/stable/operator-manual/user-management/#configuring-a-custom-root-ca-certificate-for-communicating-with-the-oidc-provider
      rootCA: |
        ${indent(8, trimspace(local.letsencrypt_staging_ca_pem))}
%{endif~}

  rbac:
    policy.csv: |
      g, IntegratedDynamic:Admin, role:admin
    policy.default: role:readonly

# The chart's own embedded Dex is redundant now that ArgoCD talks OIDC
# directly to our shared Dex — turned off rather than run two.
dex:
  enabled: false

# Chart ships resources: {} for every component below by default —
# confirmed live 2026-08-11: with every platform chart requestless (this
# one included), the scheduler has nothing to balance the pool's 2 nodes on
# and Cluster Autoscaler never sees a reason to reach for the 3rd, so a
# fresh scaleway-homelab boot piles ~30 pods onto one node's worth of real
# RAM and OOMs (see gitops repo's services/platform/cert-manager/applications/scaleway/chart.vendor.yaml
# for the fix applied to the rest of the platform, same reasoning here).
#
# Sized from `kubectl top pods -n argocd` on the live cluster (2026-08-11,
# two samples ~15min apart), not from chart-doc guesses — a first pass
# anchored on generic recommendations instead of this cluster's actual
# usage left controller's limit (512Mi) barely above its observed 405-471Mi,
# no real headroom at all. controller is the standout: it watches the live
# state of every resource this whole GitOps repo manages, so its memory
# scales with total tracked resource count, not just "idle controller
# usage" — request is set above the observed band, limit well above it.
# repoServer's memory/CPU spikes with whatever chart it's rendering at that
# moment (kube-prometheus-stack is the largest one synced here), hence the
# same generous limit despite low observed idle usage (8m/131Mi).
controller:
  replicas: 1
  # Small node pool (see the "small nodes, no real headroom" comment on
  # repoServer's sizing below) -- system-cluster-critical (built into every
  # Kubernetes cluster, usable outside kube-system unlike
  # system-node-critical) protects this pod specifically from the kubelet's
  # own node-memory-pressure eviction (confirmed live 2026-08-20: this pod
  # was evicted at 91% of a node's memory even while under its own
  # container limit -- a different mechanism than the cgroup OOM kill
  # GOMEMLIMIT below addresses) and gives it scheduling priority over
  # everything else in this namespace.
  priorityClassName: system-cluster-critical
  # NOT sharded, on purpose: Argo CD's controller sharding
  # (ARGOCD_CONTROLLER_REPLICAS + --sharding-method) splits load by
  # *registered cluster*, never by Application/namespace/resource within
  # one cluster -- confirmed against the docs and community sources, not
  # assumed. This instance only ever registers one cluster (itself,
  # https://kubernetes.default.svc), so every additional replica would
  # sit fully idle: nothing to shard to it. Kept at 1 rather than chasing
  # an HA pattern that's a no-op here — see resource.exclusions and
  # GOMEMLIMIT below for the levers that actually apply to a
  # single-cluster controller.
  metrics:
    enabled: true
    serviceMonitor:
      enabled: true
      additionalLabels:
        release: kube-prometheus-stack
  # GOMEMLIMIT (see the locals block above this resource): observed live
  # 2026-08-20 that even 2048Mi wasn't enough headroom during a full
  # 22-Application reconcile burst -- OOMKilled twice before stabilizing.
  # Rather than keep raising the hard limit, this makes the controller GC
  # proactively at ${local.argocd_controller_gomemlimit_mib}MiB instead of
  # waiting for the kernel to kill it at the ${local.argocd_controller_memory_limit_mib}Mi
  # cgroup limit below.
  env:
    - name: GOMEMLIMIT
      value: "${local.argocd_controller_gomemlimit_mib}MiB"
  resources:
    requests:
      cpu: 50m
      # Bumped 2026-08-19: confirmed live, OOMKilled repeatedly (6+ times)
      # reconciling a fresh cluster boot with the gitops repo's Argo
      # Workflows addition (argo-workflows, argo-workflows-secret,
      # terraform-apply + its 3 CronWorkflows) pushing total tracked
      # resource count past what 512Mi/1024Mi had headroom for -- the
      # comment above already flagged that pairing as "no real headroom
      # at all" before this addition.
      memory: 768Mi
    limits:
      # Bumped 1000m -> 3000m 2026-08-24: confirmed live, the controller was
      # CPU-throttled (CFS quota) during a fresh cluster boot's full-tree
      # reconcile while the node itself sat nowhere near its own CPU
      # capacity (DEV1-M: 3800m allocatable, ~300m/7% in use) -- unlike the
      # memory limit above, there's no node-pressure reason to keep this
      # tight, so it's raised well past the request instead of paired with
      # a throttling-avoidance mechanism the way GOMEMLIMIT addresses OOMs.
      cpu: 3000m
      # Lowered from 2048Mi 2026-08-20: paired with GOMEMLIMIT above instead
      # of just raising this further -- see that env var's own comment.
      memory: "${local.argocd_controller_memory_limit_mib}Mi"

repoServer:
  replicas: 1
  metrics:
    enabled: true
    serviceMonitor:
      enabled: true
      additionalLabels:
        release: kube-prometheus-stack
  resources:
    requests:
      cpu: 25m
      memory: 192Mi
    limits:
      # Bumped 1000m -> 3000m 2026-08-24, same reasoning as controller's CPU
      # limit above: repo-server renders every chart in the tree during that
      # same startup burst and was observed throttled well below the node's
      # actual free CPU.
      cpu: 3000m
      memory: 768Mi

server:
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

redis:
  resources:
    requests:
      cpu: 10m
      memory: 64Mi
    limits:
      cpu: 100m
      memory: 128Mi

applicationSet:
  # Beta feature (argo-helm/argo-cd chart): without this flag, the
  # argocd.argoproj.io/sync-wave annotation on Applications generated by an
  # ApplicationSet does nothing — each generated Application is created and
  # auto-synced independently, with no ordering across them. Needed by
  # gitops's services-app-scaleway ApplicationSet (bootstrap/templates/scaleway.yaml),
  # whose RollingSync strategy groups Velero/external-dns/Dex/Grafana after
  # the OpenBao-backed Secrets their own sibling -init/-config apps produce
  # — confirmed live 2026-08-11 that plain sync-wave annotations alone did
  # not prevent those pods starting before their credentials existed.
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

resource "helm_release" "argocd_apps" {
  name      = "argocd-apps"
  namespace = "argocd"

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.4"

  # Applies to both install AND uninstall (the provider uses the same
  # timeout for whichever Helm operation this resource is currently
  # performing) -- default (300s) isn't enough for uninstall since
  # bootstrap's own resources-finalizer.argocd.argoproj.io (see values
  # below) now makes its deletion wait for ArgoCD to cascade-delete its
  # entire child-Application tree first, confirmed live (2026-08-25) to
  # exceed 5 minutes.
  timeout = 1800

  # module.wait_all_domains_healthy (below) is the real Terraform-enforced
  # prerequisite: bootstrap's Application must not even be created until
  # every platform domain is Healthy — see platform-apps/README.md.
  depends_on = [helm_release.argocd, module.wait_all_domains_healthy]

  values = [<<EOF
applications:
  bootstrap:
    namespace: argocd
    # Cascade-deletes this Application's own managed resources (its child
    # Applications' Application CRs, one level of the app-of-apps tree)
    # before removing this object itself, instead of the default "just
    # forget about it, leave whatever it deployed running" behavior.
    # Confirmed live (2026-08-25): without this, a `terraform destroy`
    # tears down helm_release.argocd_apps/argocd (and, before this was
    # split per-domain, the old combined argocd_platform_apps) in
    # ~13s combined -- nowhere near enough for anything to gracefully
    # shut down -- leaving e.g. Velero's own pod orphaned right before
    # kubernetes_namespace.velero's cascade delete races its controller's
    # own teardown for the Restore CRs' finalizers (see that resource's
    # own comment in main.tf). https://argo-cd.readthedocs.io/en/stable/user-guide/app_deletion/#about-the-deletion-finalizer
    finalizers:
      - resources-finalizer.argocd.argoproj.io
    project: default

    source:
      repoURL: https://github.com/IntegratedDynamic/gitops.git
      targetRevision: ${local.effective_gitops_revision}
      path: bootstrap
      helm:
        parameters:
          - name: env
            value: scaleway
          - name: revision
            value: ${local.effective_gitops_revision}

    destination:
      server: https://kubernetes.default.svc
      namespace: argocd

    syncPolicy:
      # Since this application bootstrap all the gitops repo, it's equal to cluster startup duration, which is greated than default argocd timeout values.
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

# ── Secrets/monitoring/backups/networking/wireguard, extracted from gitops repo (infra#84 + follow-up) ───
#
# Each domain below is its OWN helm_release (one Application each), instead
# of the single combined helm_release.argocd_platform_apps this used to be
# -- required so Terraform can express real depends_on edges BETWEEN
# domains (Helm gives no ordering guarantee across sibling resources of one
# release, which is exactly what let secrets-apps/networking-apps race each
# other's teardown before this split -- see platform-apps/README.md's
# "Generalizing the finalizer-race fix" section). Each still points at this
# repo's own platform-apps/ chart (not gitops) for its OWN list of child
# Applications -- see that chart's README.md for the full "why" on the
# chart-level mechanics (ArgoCD sync-wave only orders resources within one
# parent Application's own sync). The child Applications' own charts
# (services/platform/openbao/chart, monitoring/chart, ...) are untouched,
# still pulled from the gitops repo, same as before this split — only which
# parent Application claims them as managed resources changed.
#
# Common shape every one of these helm_release resources shares: same
# repository/chart/version (upstream argoproj argocd-apps, renders one
# Application per values file's `applications:` key), same timeout = 1800
# (uninstall must wait for ArgoCD to cascade-delete the whole child-tree via
# resources-finalizer.argocd.argoproj.io -- confirmed live 2026-08-25 this
# exceeds 5 minutes), same finalizers/syncPolicy shape. Only name,
# valueFiles, and depends_on vary per domain -- documented per-resource
# below rather than factored into a module, since Terraform's helm_release
# doesn't support a for_each-friendly way to vary depends_on per instance
# without losing the explicit, greppable per-domain comments this file
# already relies on elsewhere.
locals {
  # Shared skeleton for every domain's single-Application `applications:`
  # values block -- only the domain name + valueFile actually change.
  platform_apps_source_repo = "https://github.com/IntegratedDynamic/infrastructure.git"

  # var.letsencrypt_staging (see that variable's own comment): which
  # ClusterIssuer gateway-config's Gateway actually uses. Threaded into
  # networking_resources_apps' own Application parameters below (same
  # pattern values-crossplane.yaml's gitRefParam/infraRevision already
  # establishes), which platform-apps/templates/apps.yaml then injects into
  # gateway-config's own child Application via its activeClusterIssuerParam
  # flag (values-networking-resources.yaml).
  active_cluster_issuer = var.letsencrypt_staging ? "letsencrypt-staging" : "letsencrypt-prod"
}

# ── Tier -1: crds-apps, every CRD-only chart across the whole platform ──────
#
# The one domain every controller-tier domain below (monitoring-apps,
# networking-controllers-apps) that genuinely needs a CRD depends on
# before it's even created -- see module.wait_crds_healthy right after it,
# and platform-apps/README.md's "One CRDs domain for the whole platform"
# section for the full history. secrets-apps/backups-apps/wireguard-apps do
# NOT depend on it (2026-08-26/27 generalization, infra#100; secrets-apps
# regained self-managed CRDs in the 2026-08-27 revert): OpenBao,
# wireguard-config, external-secrets and velero each either consume no CRD
# or install their own, so gating them "uniformly" the way this domain's
# list used to be reasoned about would just be dead time -- see
# values-secrets.yaml / values-backups.yaml.
#
# Generalizes what used to be two separate, scattered CRD-only Applications
# (kube-prometheus-stack-crds inside monitoring-apps since 2026-08-13,
# gateway-api-crds inside networking-apps for about an hour on 2026-08-26)
# into a single upfront gate, then extended (2026-08-26/27) past those two
# to every CRD-bearing platform component (external-secrets, cert-manager,
# velero -- see values-crds.yaml's own header for the one deliberate
# exception, argo-workflows): no product chart anywhere in this platform
# can start before every CRD this repo installs already exists, closing
# off that whole class of race (confirmed live 2026-08-26:
# envoy-gateway/cert-manager racing for who installs the Gateway API CRDs
# cost cert-manager 4 crash-loops and a ~40s CrashLoopBackOff tax even
# after the CRDs were genuinely Established).
#
# depends_on ONLY helm_release.argocd: CRD registration needs nothing but
# the API server reachable, no Secret, no other domain.
resource "helm_release" "crds_apps" {
  name      = "argocd-crds-apps"
  namespace = "argocd"

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.4"

  timeout = 1800

  depends_on = [
    helm_release.argocd,
  ]

  values = [<<EOF
applications:
  crds-apps:
    namespace: argocd
    finalizers:
      - resources-finalizer.argocd.argoproj.io
    project: default
    source:
      repoURL: ${local.platform_apps_source_repo}
      targetRevision: ${local.effective_infra_revision}
      path: 10-cluster/scaleway/platform-apps
      helm:
        valueFiles:
          - values-crds.yaml
        parameters:
          - name: revision
            value: ${local.effective_gitops_revision}
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

# Real Terraform-enforced prerequisite of every Tier-0 domain -- ArgoCD has
# no native way to say "don't even create Application X until Application Y
# is genuinely Healthy" across independent top-level Applications, same
# reasoning as every other module.wait_*_healthy gate in this file. Reuses
# the shared wait_platform_apps RBAC (kubernetes_service_account/role/
# role_binding, defined further down this file) -- Terraform resolves that
# dependency by graph, not by file order.
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

resource "helm_release" "secrets_apps" {
  name      = "argocd-secrets-apps"
  namespace = "argocd"

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.4"

  timeout = 1800

  # openbao/openbao-init merged BACK IN here as wave 0 (2026-08-27,
  # see values-secrets.yaml's own header) -- the old standalone-apps
  # Application and its wait_standalone_healthy Job are gone, that
  # cross-Application OpenBao-readiness hop is now the wave 0 -> wave 1
  # boundary inside THIS Application (secrets-sync in wave 1 only advances
  # once wave 0's OpenBao is ArgoCD-health-check-settled, the same
  # guarantee the deleted Job enforced). eso-data-apps merged in too, as
  # wave 2.
  #
  # scaleway_s3_credentials/openbao_unseal_aws: kept in depends_on (moved
  # here from the deleted standalone-apps) -- this Application now manages
  # the openbao child Application again and writes into the openbao
  # namespace, so it must still be guaranteed to finish its own
  # cascade-delete before kubernetes_namespace.openbao's destroy (confirmed
  # live 2026-08-25: ArgoCD's openbao Application was mid-retry writing into
  # that namespace while Terraform deleted it directly).
  #
  # No module.wait_crds_healthy (2026-08-27 revert -- see values-crds.yaml's
  # own comment): external-secrets manages its own CRDs again, and OpenBao
  # needs no CRD at all -- starts in parallel with crds-apps.
  depends_on = [
    helm_release.argocd,
    kubernetes_secret.scaleway_s3_credentials,
    kubernetes_secret.openbao_unseal_aws,
  ]

  values = [<<EOF
applications:
  secrets-apps:
    namespace: argocd
    # Cascade-deletes this domain's own child Applications (openbao,
    # openbao-init, external-secrets, secrets-sync, every *-secret
    # ExternalSecret) before removing this object -- see `bootstrap`'s own
    # finalizers comment above for the full "why".
    finalizers:
      - resources-finalizer.argocd.argoproj.io
    project: default
    source:
      repoURL: ${local.platform_apps_source_repo}
      targetRevision: ${local.effective_infra_revision}
      path: 10-cluster/scaleway/platform-apps
      helm:
        valueFiles:
          - values-secrets.yaml
        parameters:
          - name: revision
            value: ${local.effective_gitops_revision}
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

# The ONE surviving Terraform gate for the whole secrets tree. Since the
# 2026-08-27 merge (values-secrets.yaml) this single `secrets-apps`
# Application holds OpenBao (wave 0), external-secrets (wave 0),
# secrets-sync (wave 1), and every product's ExternalSecret (wave 2) --
# so this one Synced+Healthy check now transitively covers everything the
# deleted wait_standalone_healthy and the deleted "eso_data_apps after a
# real wait_secrets_healthy" hop used to enforce as separate
# cross-Application Jobs:
#
#  - OpenBao genuinely ready to serve Kubernetes-auth logins (not just
#    "pod Ready" -- raft-snapshot restore done, Kubernetes auth backend
#    reloaded). Enforced by wave 0 -> wave 1 inside the Application now;
#    confirmed live 2026-08-27 that losing this ordering gave ESO a
#    persistent (multi-minute, non-self-healing) "403 permission denied"
#    on its OpenBao login.
#  - external-secrets.io CRDs Established before secrets-sync's
#    ClusterSecretStore/PushSecret sync (external-secrets manages its own
#    CRDs again -- 2026-08-27 revert, see values-crds.yaml). wave 0 ->
#    wave 1 again.
#  - ESO's ValidatingWebhookConfiguration actually serving before any
#    product ExternalSecret syncs -- confirmed live 2026-08-26 (as the old
#    eso-data-apps) that without this the ExternalSecrets fail outright, a
#    hard non-self-healing sync error, NOT the "briefly races, self-heals
#    via ESO's own refreshInterval" tolerance every downstream CONSUMER of
#    those Secrets gets to rely on. wave 1 -> wave 2.
#
# Every domain that used to gate on wait_standalone_healthy or on
# helm_release.eso_data_apps now gates on this module (hard) or on
# helm_release.secrets_apps (soft create-order + destroy-ordering, which
# also protects every ExternalSecret's
# externalsecrets.external-secrets.io/externalsecret-cleanup finalizer:
# "A depends_on B" => A destroys before B, so a consumer domain listing
# secrets_apps is guaranteed to finish tearing down before ESO's own
# controller does).
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

resource "helm_release" "monitoring_apps" {
  name      = "argocd-monitoring-apps"
  namespace = "argocd"

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.4"

  timeout = 1800

  # No ESO ExternalSecret in this domain (thanos/loki/tempo credentials are
  # Terraform-originated Secrets, see platform-apps/README.md's
  # "secret-delivery pattern") -- no ordering dependency on secrets-apps
  # needed, stays fully parallel with it, same as before this split.
  # module.wait_crds_healthy (2026-08-26): kube-prometheus-stack's own CRDs
  # now live in the shared crds-apps domain instead of a wave nested here.
  depends_on = [
    helm_release.argocd,
    module.wait_crds_healthy,
    kubernetes_secret.thanos_objstore_config,
    kubernetes_secret.loki_s3_credentials,
    kubernetes_secret.tempo_s3_credentials,
  ]

  values = [<<EOF
applications:
  monitoring-apps:
    namespace: argocd
    # Cascade-deletes this domain's own child Applications
    # (kube-prometheus-stack, loki, tempo, ...) before removing this
    # object -- see `bootstrap`'s own finalizers comment above.
    finalizers:
      - resources-finalizer.argocd.argoproj.io
    project: default
    source:
      repoURL: ${local.platform_apps_source_repo}
      targetRevision: ${local.effective_infra_revision}
      path: 10-cluster/scaleway/platform-apps
      helm:
        valueFiles:
          - values-monitoring.yaml
        parameters:
          - name: revision
            value: ${local.effective_gitops_revision}
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

resource "helm_release" "backups_apps" {
  name      = "argocd-backups-apps"
  namespace = "argocd"

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.4"

  timeout = 1800

  # Since the 2026-08-27 merge (values-backups.yaml) this domain holds
  # velero (wave 0) AND its two restore hooks cert-restore/grafana-restore
  # (wave 1) -- the deleted restore-apps Application and its
  # wait_restore_healthy Job are gone, that cross-Application hop is now the
  # wave 0 -> wave 1 boundary inside THIS Application.
  #
  # No ESO ExternalSecret in this domain (velero's credential is
  # Terraform-originated). null_resource.velero_namespace_predelete_cleanup
  # (main.tf) stays listed here specifically, for the DESTROY direction: "A
  # depends_on B" means A destroys before B, so listing that null_resource
  # here makes THIS release destroy (and therefore Velero's controller die)
  # BEFORE that cleanup's local-exec runs -- see that resource's own comment
  # in main.tf for the two earlier, wrong attempts at this ordering.
  # module.wait_crds_healthy dropped (2026-08-27 revert -- see
  # values-crds.yaml's own comment): velero manages its own velero.io CRDs
  # again, no external CRD dependency left -- starts in parallel with
  # crds-apps.
  depends_on = [
    helm_release.argocd,
    kubernetes_secret.velero_scaleway_credentials,
    null_resource.velero_namespace_predelete_cleanup,
  ]

  values = [<<EOF
applications:
  backups-apps:
    namespace: argocd
    # Cascade-deletes this domain's own child Applications (velero,
    # cert-restore, grafana-restore) before removing this object -- the
    # specific fix for the finalizer race:
    # gives Velero's own pod a real, ArgoCD-orchestrated shutdown instead
    # of being torn down by helm_release.argocd's uninstall with no
    # coordination -- see `bootstrap`'s own finalizers comment above.
    finalizers:
      - resources-finalizer.argocd.argoproj.io
    project: default
    source:
      repoURL: ${local.platform_apps_source_repo}
      targetRevision: ${local.effective_infra_revision}
      path: 10-cluster/scaleway/platform-apps
      helm:
        valueFiles:
          - values-backups.yaml
        parameters:
          - name: revision
            value: ${local.effective_gitops_revision}
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

# The ONE surviving Terraform gate for the whole backups tree. Since the
# 2026-08-27 merge (values-backups.yaml) this single `backups-apps`
# Application holds velero (wave 0) AND cert-restore/grafana-restore
# (wave 1), so this one Synced+Healthy check now transitively covers both
# Velero being genuinely healthy AND the two restore Jobs having finished
# (or explicitly skipped, fail-open) -- what the deleted wait_restore_healthy
# used to enforce as a separate cross-Application Job. cert-restore/
# grafana-restore's own restore Jobs need Velero's controller genuinely
# serving before they can query/create a Restore object; the wave 0 -> wave
# 1 boundary inside this Application is what guarantees that now.
# networking-resources-apps and grafana-apps gate on this module instead of
# the deleted wait_restore_healthy.
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

  # Split out of the old combined networking-apps (2026-08-26/27
  # generalization, infra#100) -- envoy-gateway/cert-manager consume
  # nothing but crds-apps being Established (module.wait_crds_healthy),
  # not any ExternalSecret, so unlike networking-resources-apps below this
  # domain has no dependency on secrets-apps at all.
  depends_on = [
    helm_release.argocd,
    module.wait_crds_healthy,
  ]

  values = [<<EOF
applications:
  networking-controllers-apps:
    namespace: argocd
    # Cascade-deletes this domain's own child Applications (envoy-gateway,
    # cert-manager, ...) before removing this object -- see `bootstrap`'s
    # own finalizers comment above.
    finalizers:
      - resources-finalizer.argocd.argoproj.io
    project: default
    source:
      repoURL: ${local.platform_apps_source_repo}
      targetRevision: ${local.effective_infra_revision}
      path: 10-cluster/scaleway/platform-apps
      helm:
        valueFiles:
          - values-networking-controllers.yaml
        parameters:
          - name: revision
            value: ${local.effective_gitops_revision}
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

# Real Terraform-enforced prerequisite of networking-resources-apps below --
# gateway-config's ClusterIssuers are cert-manager.io-typed and its sync
# fails outright (no self-heal) if cert-manager's own webhook isn't
# registered and serving yet, a genuinely stronger requirement than "the
# CRD exists" (crds-apps' own gate). Same wait-module pattern as every
# other cross-domain health gate in this file.
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

  # Since the 2026-08-27 merge (values-networking-resources.yaml) this
  # single Application holds gateway-config/external-dns (wave 0) AND every
  # product's `*-gateway` HTTPRoute chart (wave 1) -- the deleted
  # gateways-apps Application and its wait_networking_resources_healthy Job
  # are gone, that cross-Application hop is now the wave 0 -> wave 1
  # boundary inside THIS Application (every `*-gateway` in wave 1 attaches
  # to the `Gateway` object wave 0's gateway-config creates, and needs
  # nothing else wave 0 didn't already need).
  #
  # Networking CONTROLLERS deliberately stay a SEPARATE Application
  # (helm_release.networking_controllers_apps) -- NOT merged in as an
  # earlier wave here. Terraform can only gate an Application's creation,
  # not pause mid-sync between two of its own waves, so folding the
  # controllers in would force them to also wait for Secrets+Backups below
  # before starting, for no reason (today they start as soon as crds-apps
  # is Established). See Draft-proposal.md's "Correction" section.
  #
  # Gates:
  #  - module.wait_networking_controllers_healthy (hard): gateway-config's
  #    ClusterIssuers are cert-manager.io-typed and fail outright at the API
  #    level if cert-manager's webhook isn't registered and serving yet.
  #  - module.wait_secrets_healthy (hard, upgraded 2026-08-27 from the old
  #    soft `depends_on = [eso_data_apps]`): gateway-config/external-dns
  #    consume cert-manager-webhook-secret/external-dns-secret, and merge 1
  #    made wait_secrets_healthy the single check covering every
  #    ExternalSecret's webhook-serving readiness (plus the
  #    externalsecret-cleanup finalizer's destroy-ordering).
  #  - module.wait_backups_healthy (2026-08-27, was wait_restore_healthy):
  #    gateway-config's wildcard TLS Secret restore is now wave 1 of
  #    backups-apps.
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
    # Cascade-deletes this domain's own child Applications (gateway-config,
    # external-dns, every *-gateway HTTPRoute chart) before removing this
    # object -- see `bootstrap`'s own finalizers comment above.
    finalizers:
      - resources-finalizer.argocd.argoproj.io
    project: default
    source:
      repoURL: ${local.platform_apps_source_repo}
      targetRevision: ${local.effective_infra_revision}
      path: 10-cluster/scaleway/platform-apps
      helm:
        valueFiles:
          - values-networking-resources.yaml
        parameters:
          - name: revision
            value: ${local.effective_gitops_revision}
          # var.letsencrypt_staging (see argocd.tf's local.active_cluster_issuer
          # and that variable's own comment) -- picked up by gateway-config's
          # own entry in values-networking-resources.yaml
          # (activeClusterIssuerParam: true).
          - name: activeClusterIssuer
            value: ${local.active_cluster_issuer}
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

resource "helm_release" "wireguard_apps" {
  name      = "argocd-wireguard-apps"
  namespace = "argocd"

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.4"

  timeout = 1800

  # wireguard-secret now lives in secrets-apps' wave 2 (see
  # values-secrets.yaml) -- wireguard-config just consumes the Secret it
  # materializes, so this is a soft create-order + destroy-ordering
  # dependency on helm_release.secrets_apps (which also protects that
  # ExternalSecret's externalsecret-cleanup finalizer -- "A depends_on B"
  # => A destroys before ESO's own controller). No HTTPRoute in this domain
  # (wireguard-config has no Gateway API dependency), and it consumes no
  # CRD at all, so no wait on crds-apps either -- the same "don't pay for a
  # dependency you don't have" reasoning that keeps OpenBao off crds-apps.
  depends_on = [
    helm_release.argocd,
    helm_release.secrets_apps,
  ]

  values = [<<EOF
applications:
  wireguard-apps:
    namespace: argocd
    finalizers:
      - resources-finalizer.argocd.argoproj.io
    project: default
    source:
      repoURL: ${local.platform_apps_source_repo}
      targetRevision: ${local.effective_infra_revision}
      path: 10-cluster/scaleway/platform-apps
      helm:
        valueFiles:
          - values-wireguard.yaml
        parameters:
          - name: revision
            value: ${local.effective_gitops_revision}
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

# RBAC for the health-wait Job below — scoped to exactly what it needs
# (read-only on Applications in the argocd namespace), nothing broader.
# Runs as a real in-cluster Job via the Kubernetes API instead of a
# local-exec provisioner: no dependency on a local `kubectl` binary or a
# self-generated kubeconfig, works identically whether this root is applied
# from an admin's machine or CI.

# Confirmed live (2026-08-25): without an explicit depends_on, nothing
# ordered these after anything more than scaleway_k8s_cluster.this itself
# (the only hard dependency the kubernetes/helm provider configs create) --
# Terraform fired both RBAC resources ~6s after the cluster control plane
# finished, in parallel with scaleway_k8s_pool.default (which took several
# more minutes), and hit DNS resolution failures on the cluster's own API
# hostname twice in a row at exactly this point. Every kubernetes_namespace
# resource elsewhere in this file already depends_on the pool for the same
# reason; these two need it too -- and since they create objects INSIDE the
# `argocd` namespace, which helm_release.argocd itself creates
# (create_namespace = true), depending on that release directly covers
# both "pool is ready" (it has its own depends_on) and "the namespace these
# actually need exists" in one dependency.
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

# ── Tier 1: dex/argocd-config/grafana, extracted from gitops repo (infra#84 follow-up) ───
#
# Each of these three domains shares the identical dependency profile: a
# soft dependency on helm_release.secrets_apps (for its own consumed
# Secret, now secrets-apps' wave 2 -- see values-secrets.yaml) -- but each
# stays its OWN helm_release/Application rather than one bundled domain,
# since argo-workflows-apps (Tier 2, below) needs to health-wait on dex
# specifically, not a bundle diluted by argocd-config/grafana's unrelated
# health.
#
# None of the three depends on networking's Gateway object directly -- that
# dependency belonged to each domain's own `*-gateway` HTTPRoute chart, not
# the product itself, and now lives in networking-resources-apps' wave 1
# (2026-08-27 merge -- was the separate gateways-apps Application). See
# platform-apps/README.md's "Decoupling gateway routes" section.
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
      targetRevision: ${local.effective_infra_revision}
      path: 10-cluster/scaleway/platform-apps
      helm:
        valueFiles:
          - values-dex.yaml
        parameters:
          - name: revision
            value: ${local.effective_gitops_revision}
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

resource "helm_release" "argocd_config_apps" {
  name      = "argocd-argocd-config-apps"
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
  argocd-config-apps:
    namespace: argocd
    finalizers:
      - resources-finalizer.argocd.argoproj.io
    project: default
    source:
      repoURL: ${local.platform_apps_source_repo}
      targetRevision: ${local.effective_infra_revision}
      path: 10-cluster/scaleway/platform-apps
      helm:
        valueFiles:
          - values-argocd-config.yaml
        parameters:
          - name: revision
            value: ${local.effective_gitops_revision}
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

  # module.wait_backups_healthy (2026-08-27, was wait_restore_healthy):
  # grafana's own PVC restore (grafana-restore) is now wave 1 of
  # backups-apps, so the single wait_backups_healthy check covers it --
  # replacing both the old separate restore-apps Application and, before
  # that, the "PreSync hook on grafana-chart itself, fails open" design.
  # helm_release.secrets_apps (was eso_data_apps): grafana-secret is now
  # secrets-apps' wave 2.
  depends_on = [
    helm_release.argocd,
    helm_release.secrets_apps,
    module.wait_backups_healthy,
    # Referencing a count-based resource directly (no index/splat) depends
    # on ALL of its instances -- zero of them when var.letsencrypt_staging
    # is false, so this is a no-op in that case, not an error.
    kubernetes_config_map.letsencrypt_staging_ca_monitoring,
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
      targetRevision: ${local.effective_infra_revision}
      path: 10-cluster/scaleway/platform-apps
      helm:
        valueFiles:
          - values-grafana.yaml
        parameters:
          - name: revision
            value: ${local.effective_gitops_revision}
          # var.letsencrypt_staging (see that variable's own comment) --
          # picked up by grafana's own entry in values-grafana.yaml
          # (extraValueFileParam), which conditionally appends the merge-CA
          # values file trusting the staging root.
          - name: letsEncryptStaging
            value: "${var.letsencrypt_staging}"
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

# ── Tier 2: argo-workflows, extracted from gitops repo (infra#84 follow-up) ───
#
# argo-workflows/chart eager-dials Dex's OIDC issuer at pod startup and
# crash-loops if Dex isn't reachable -- a real hard dependency, unlike ESO's
# self-heal tolerance. Waits on dex-apps specifically (not a bundle) for
# exactly this reason -- see values-dex.yaml's own header comment for why
# dex-apps stayed its own domain.
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
      targetRevision: ${local.effective_infra_revision}
      path: 10-cluster/scaleway/platform-apps
      helm:
        valueFiles:
          - values-argo-workflows.yaml
        parameters:
          - name: revision
            value: ${local.effective_gitops_revision}
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

# ── Tier 3: crossplane, extracted from gitops repo (infra#84 follow-up; issue #101) ───
#
# Crossplane core + upbound/provider-opentofu -- the unattended `tofu apply`
# loop for 11-secrets/openbao/managed and 12-monitoring/grafana/{bootstrap,
# managed}, replacing the terraform-apply CronWorkflows (issue #101). The
# openbao/managed Workspace's own vault provider talks to OpenBao's
# in-cluster Service, so this gates on module.wait_secrets_healthy; the two
# grafana Workspaces (their grafana provider + grafana/bootstrap's folded-in
# infra#82 self-heal probe both hit Grafana's live API) gate on
# module.wait_grafana_healthy below. Neither is a hard blocker for the
# Workspaces to eventually converge -- provider-opentofu retries on its own
# backoff -- but starting crossplane-apps before either tool is up would
# just burn reconcile attempts.
module "wait_grafana_healthy" {
  source = "./modules/wait-argocd-apps-healthy"

  job_name  = "wait-grafana-healthy"
  app_names = ["grafana-apps"]

  service_account_name = kubernetes_service_account.wait_platform_apps.metadata[0].name
  revision_trigger     = helm_release.grafana_apps.metadata.revision

  depends_on = [
    helm_release.grafana_apps,
    kubernetes_role_binding.wait_platform_apps,
  ]
}

resource "helm_release" "crossplane_apps" {
  name      = "argocd-crossplane-apps"
  namespace = "argocd"

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.4"

  timeout = 1800

  depends_on = [
    helm_release.argocd,
    module.wait_secrets_healthy,
    module.wait_grafana_healthy,
  ]

  values = [<<EOF
applications:
  crossplane-apps:
    namespace: argocd
    finalizers:
      - resources-finalizer.argocd.argoproj.io
    project: default
    source:
      repoURL: ${local.platform_apps_source_repo}
      targetRevision: ${local.effective_infra_revision}
      path: 10-cluster/scaleway/platform-apps
      helm:
        valueFiles:
          - values-crossplane.yaml
        parameters:
          - name: revision
            value: ${local.effective_gitops_revision}
          # infra#76: threads THIS repo's own revision through so
          # crossplane-config's gitRefParam (values-crossplane.yaml)
          # overrides its chart's `gitRef: main` default -- every
          # Workspace's git module `?ref=` then follows the infra branch
          # under test.
          - name: infraRevision
            value: ${local.effective_infra_revision}
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

# The Terraform-enforced prerequisite itself: every platform domain must
# reach Healthy before bootstrap's own Application resource is even created
# (see that resource's depends_on above) — ArgoCD has no native way to
# express "wait for these independent top-level Applications" (sync-wave
# doesn't cross Application boundaries), so this is enforced as a real
# Terraform apply-order dependency instead. Factored into the
# wait-argocd-apps-healthy module (infra#84 follow-up) once the platform-apps
# DAG grew past the original flat "four domains in parallel, then bootstrap"
# shape — this is now the FINAL gate in that DAG, not the only one; see
# platform-apps/README.md for the full DAG and the other, narrower gates
# (module "wait_networking_controllers_healthy", "wait_secrets_healthy",
# "wait_backups_healthy", "wait_dex_healthy", etc.) that sit between
# individual domains. Named for what it now actually checks — every
# domain, not just the original four "platform apps".
#
# app_names lists every top-level domain Application by name, not just the
# DAG's leaves: checking leaves alone would work (a leaf can't be Healthy
# without its own ancestors having already succeeded), but listing
# everything explicitly is the same defensive, easy-to-audit style the
# original four-app version of this check already used — a leaf-only list
# would be a subtler invariant to keep correct as domains are added/removed.
# The 2026-08-27 merges (standalone-apps folded into secrets-apps' wave 0,
# eso-data-apps into its wave 2, restore-apps into backups-apps' wave 1,
# gateways-apps into networking-resources-apps' wave 1) removed three
# entries here — the merged children are covered transitively via each
# surviving parent Application's own recursive health
# (resource.customizations.health.argoproj.io_Application).
module "wait_all_domains_healthy" {
  source = "./modules/wait-argocd-apps-healthy"

  job_name = "wait-all-domains-healthy"
  app_names = [
    "crds-apps",
    "secrets-apps",
    "monitoring-apps",
    "backups-apps",
    "networking-controllers-apps",
    "networking-resources-apps",
    "wireguard-apps",
    "dex-apps",
    "argocd-config-apps",
    "grafana-apps",
    "argo-workflows-apps",
    "crossplane-apps",
  ]
  service_account_name = kubernetes_service_account.wait_platform_apps.metadata[0].name

  # Forces a fresh Job whenever ANY watched domain is redeployed, and
  # supplies the implicit Terraform dependency on all of them — see the
  # module's own revision_trigger description. Joining every domain's own
  # revision means a change to any one of them alone is enough to trigger a
  # fresh Job, same "re-run the wait on redeploy" behavior the original
  # single-domain PLATFORM_APPS_REVISION env var had.
  revision_trigger = join(",", [
    helm_release.crds_apps.metadata.revision,
    helm_release.secrets_apps.metadata.revision,
    helm_release.monitoring_apps.metadata.revision,
    helm_release.backups_apps.metadata.revision,
    helm_release.networking_controllers_apps.metadata.revision,
    helm_release.networking_resources_apps.metadata.revision,
    helm_release.wireguard_apps.metadata.revision,
    helm_release.dex_apps.metadata.revision,
    helm_release.argocd_config_apps.metadata.revision,
    helm_release.grafana_apps.metadata.revision,
    helm_release.argo_workflows_apps.metadata.revision,
    helm_release.crossplane_apps.metadata.revision,
  ])

  depends_on = [
    helm_release.crds_apps,
    helm_release.secrets_apps,
    helm_release.monitoring_apps,
    helm_release.backups_apps,
    helm_release.networking_controllers_apps,
    helm_release.networking_resources_apps,
    helm_release.wireguard_apps,
    helm_release.dex_apps,
    helm_release.argocd_config_apps,
    helm_release.grafana_apps,
    helm_release.argo_workflows_apps,
    helm_release.crossplane_apps,
    kubernetes_role_binding.wait_platform_apps,
  ]
}

# Confirmed live (2026-08-25): without this, `terraform apply` reports
# success the moment helm_release.argocd_apps creates the bootstrap
# Application *object* — Helm's own --wait readiness checks understand
# built-in Kubernetes kinds (Deployment/StatefulSet/PVC/...), not ArgoCD's
# Application CRD health semantics, so it doesn't actually wait for
# bootstrap's own sync to finish. That's misleading on its own (an apply
# reported "done" while the cluster is still converging its entire
# gitops-repo tree underneath it), and it directly caused real confusion
# mid-session: a `terraform destroy` issued right after such an apply hit
# bootstrap still mid-forward-sync (waiting on its own wave 2), and only
# started actually cascade-deleting once that finished — several extra
# minutes of "why is this still creating things during a destroy" that a
# genuine wait here would have avoided by making `apply` block until
# bootstrap is truly done converging. Reuses the same RBAC as
# wait_platform_apps_healthy above (same permissions: read Applications
# in argocd) — no reason for a second ServiceAccount/Role pair.
resource "kubernetes_job_v1" "wait_bootstrap_healthy" {
  metadata {
    name      = "wait-bootstrap-healthy"
    namespace = "argocd"
  }

  spec {
    # bootstrap's own tree is at least as deep as the four platform-apps
    # domains combined (dex, grafana, wireguard, argo-workflows, demo, every
    # remaining *-gateway chart) — same budget as
    # wait_platform_apps_healthy, no evidence yet it needs to differ.
    active_deadline_seconds = 1800
    backoff_limit           = 0

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name" = "wait-bootstrap-healthy"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.wait_platform_apps.metadata[0].name
        restart_policy       = "Never"

        container {
          name  = "wait"
          image = "alpine/kubectl:1.35.3"

          command = ["sh", "-c", <<-EOT
            set -eu
            while true; do
              sync=$(kubectl get application bootstrap -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
              health=$(kubectl get application bootstrap -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || true)
              if [ "$sync" = "Synced" ] && [ "$health" = "Healthy" ]; then
                echo "Application/bootstrap is Synced and Healthy."
                exit 0
              fi
              echo "Application/bootstrap: sync=$${sync:-<none yet>} health=$${health:-<none yet>}"
              sleep 5
            done
          EOT
          ]

          # Same "force a fresh Job on redeploy" trick as
          # wait_platform_apps_healthy's own env var above.
          env {
            name  = "BOOTSTRAP_REVISION"
            value = helm_release.argocd_apps.metadata.revision
          }
        }
      }
    }
  }

  wait_for_completion = true

  timeouts {
    create = "35m"
  }

  depends_on = [
    helm_release.argocd_apps,
    kubernetes_role_binding.wait_platform_apps,
  ]
}
