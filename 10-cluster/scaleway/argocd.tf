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
  # repo-server) and the plain `git clone --branch` step inside
  # terraform-apply's WorkflowTemplate (infra#76's gitRef) assume the
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
}

resource "helm_release" "secrets_apps" {
  name      = "argocd-secrets-apps"
  namespace = "argocd"

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.4"

  timeout = 1800

  # scaleway_s3_credentials/openbao_unseal_aws: without them, nothing
  # ordered kubernetes_namespace.openbao's destroy after this release's own
  # -- confirmed live (2026-08-25) that ArgoCD's openbao Application (with
  # selfHeal: true, and resources-finalizer.argocd.argoproj.io) was still
  # actively retrying "create content in namespace openbao" while Terraform
  # was independently, concurrently deleting that same namespace directly.
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
    # external-secrets, ...) before removing this object -- see
    # `bootstrap`'s own finalizers comment above for the full "why".
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

# THE FIX for the ESO/ExternalSecret cross-domain finalizer race (confirmed
# live 2026-08-25, infra#84's own follow-up comment thread), generalized:
# every ExternalSecret across every platform domain (dex-secret,
# grafana-secret, wireguard-secret, argo-workflows-secret,
# argocd-config-secret, cert-manager-webhook-secret, external-dns-secret)
# lives in ONE dedicated domain here, instead of being bundled into each
# product's own domain. Each carries a
# externalsecrets.external-secrets.io/externalsecret-cleanup finalizer that
# only ESO's own controller (secrets-apps domain) ever removes -- before
# this domain existed, cert-manager-webhook-secret/external-dns-secret lived
# directly in networking-apps, which raced secrets-apps' own teardown (both
# were keys of one shared helm_release) and could strand that finalizer,
# previously requiring a manual kubectl patch.
#
# Centralizing every ExternalSecret here, with this release depending on
# secrets-apps, means EVERY product domain gets the same guarantee via the
# same single edge ("A depends_on B" => A destroys before B): this release
# (and every ExternalSecret it owns) is guaranteed to finish destroying
# before secrets-apps' own release -- and therefore ESO's own controller --
# even starts tearing down. No product domain needs its own direct
# dependency on secrets-apps for this reason anymore; they depend on THIS
# domain instead (see e.g. helm_release.networking_apps/wireguard_apps
# below), which is what actually holds the ExternalSecret they consume.
resource "helm_release" "eso_data_apps" {
  name      = "argocd-eso-data-apps"
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
  eso-data-apps:
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
          - values-eso-data.yaml
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
  depends_on = [
    helm_release.argocd,
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

  # No ESO ExternalSecret in this domain either (velero's credential is also
  # Terraform-originated). null_resource.velero_namespace_predelete_cleanup
  # (main.tf) stays listed here specifically, for the DESTROY direction: "A
  # depends_on B" means A destroys before B, so listing that null_resource
  # here makes THIS release destroy (and therefore Velero's controller die)
  # BEFORE that cleanup's local-exec runs -- see that resource's own comment
  # in main.tf for the two earlier, wrong attempts at this ordering.
  depends_on = [
    helm_release.argocd,
    kubernetes_secret.velero_scaleway_credentials,
    null_resource.velero_namespace_predelete_cleanup,
  ]

  values = [<<EOF
applications:
  backups-apps:
    namespace: argocd
    # Cascade-deletes this domain's own child Application (velero) before
    # removing this object -- the specific fix for the finalizer race:
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

resource "helm_release" "networking_apps" {
  name      = "argocd-networking-apps"
  namespace = "argocd"

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.4"

  timeout = 1800

  # cert-manager-webhook-secret/external-dns-secret used to live directly in
  # this domain -- moved to eso-data-apps (see that resource's own comment
  # for the original finalizer-race bug this fixed). envoy-gateway/
  # cert-manager/external-dns still consume those Secrets at runtime, just
  # from a different owning Application now -- depending on eso-data-apps
  # keeps their creation roughly ordered ahead of this domain's own pods
  # (same "briefly races, self-heals" tolerance every ESO consumer here
  # already accepts, not a hard requirement now that the finalizer risk
  # itself is fully owned by eso-data-apps' own depends_on).
  depends_on = [
    helm_release.argocd,
    helm_release.eso_data_apps,
  ]

  values = [<<EOF
applications:
  networking-apps:
    namespace: argocd
    # Cascade-deletes this domain's own child Applications (envoy-gateway,
    # cert-manager, gateway-config, ...) before removing this object --
    # see `bootstrap`'s own finalizers comment above.
    finalizers:
      - resources-finalizer.argocd.argoproj.io
    project: default
    source:
      repoURL: ${local.platform_apps_source_repo}
      targetRevision: ${local.effective_infra_revision}
      path: 10-cluster/scaleway/platform-apps
      helm:
        valueFiles:
          - values-networking.yaml
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

resource "helm_release" "wireguard_apps" {
  name      = "argocd-wireguard-apps"
  namespace = "argocd"

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.4"

  timeout = 1800

  # wireguard-secret itself now lives in eso-data-apps (see that resource's
  # own comment) -- wireguard-config just consumes the Secret it
  # materializes. No HTTPRoute in this domain (wireguard-config has no
  # Gateway API dependency), so unlike every HTTPRoute-bearing domain added
  # after this one, no wait on networking-apps' CRDs is needed here.
  depends_on = [
    helm_release.argocd,
    helm_release.eso_data_apps,
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
# Each of these three domains shares the identical dependency profile:
# eso-data-apps (for its own consumed Secret) + networking-apps' Gateway API
# CRDs (for its own *-gateway HTTPRoute) -- but each stays its OWN
# helm_release/Application rather than one bundled domain, since
# argo-workflows-apps (Tier 2, below) needs to health-wait on dex
# specifically, not a bundle diluted by argocd-config/grafana's unrelated
# health.
module "wait_networking_healthy" {
  source = "./modules/wait-argocd-apps-healthy"

  job_name             = "wait-networking-healthy"
  app_names            = ["networking-apps"]
  service_account_name = kubernetes_service_account.wait_platform_apps.metadata[0].name
  revision_trigger     = helm_release.networking_apps.metadata.revision

  depends_on = [
    helm_release.networking_apps,
    kubernetes_role_binding.wait_platform_apps,
  ]
}

resource "helm_release" "dex_apps" {
  name      = "argocd-dex-apps"
  namespace = "argocd"

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.4"

  timeout = 1800

  depends_on = [
    helm_release.argocd,
    helm_release.eso_data_apps,
    module.wait_networking_healthy,
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
    helm_release.eso_data_apps,
    module.wait_networking_healthy,
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

  depends_on = [
    helm_release.argocd,
    helm_release.eso_data_apps,
    module.wait_networking_healthy,
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
    helm_release.eso_data_apps,
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

# ── Tier 3: terraform-apply, extracted from gitops repo (infra#84 follow-up) ───
#
# grafana-managed's preflight calls Grafana's live HTTP API directly, and
# the PostSync initial-run-workflow hook needs argo-workflows' own
# WorkflowTemplate/CRDs already installed -- hard dependency on BOTH
# argo-workflows-apps AND grafana-apps being Healthy, not just Synced.
module "wait_argo_workflows_and_grafana_healthy" {
  source = "./modules/wait-argocd-apps-healthy"

  job_name  = "wait-argo-workflows-and-grafana-healthy"
  app_names = ["argo-workflows-apps", "grafana-apps"]

  service_account_name = kubernetes_service_account.wait_platform_apps.metadata[0].name
  revision_trigger = join(",", [
    helm_release.argo_workflows_apps.metadata.revision,
    helm_release.grafana_apps.metadata.revision,
  ])

  depends_on = [
    helm_release.argo_workflows_apps,
    helm_release.grafana_apps,
    kubernetes_role_binding.wait_platform_apps,
  ]
}

resource "helm_release" "terraform_apply_apps" {
  name      = "argocd-terraform-apply-apps"
  namespace = "argocd"

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.4"

  timeout = 1800

  depends_on = [
    helm_release.argocd,
    helm_release.eso_data_apps,
    module.wait_argo_workflows_and_grafana_healthy,
  ]

  values = [<<EOF
applications:
  terraform-apply-apps:
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
          - values-terraform-apply.yaml
        parameters:
          - name: revision
            value: ${local.effective_gitops_revision}
          # infra#76: threads THIS repo's own revision through so the
          # terraform-apply app's gitRefParam (values-terraform-apply.yaml)
          # can override its chart's hardcoded `gitRef: main` default.
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
# (module "wait_networking_healthy", "wait_dex_healthy", etc.) that sit
# between individual domains. Named for what it now actually checks — every
# domain, not just the original four "platform apps".
#
# app_names lists every domain by name, not just the DAG's leaves: checking
# leaves alone would work (a leaf can't be Healthy without its own
# ancestors having already succeeded), but listing everything explicitly is
# the same defensive, easy-to-audit style the original four-app version of
# this check already used — a leaf-only list would be a subtler invariant
# to keep correct as domains are added/removed.
module "wait_all_domains_healthy" {
  source = "./modules/wait-argocd-apps-healthy"

  job_name = "wait-all-domains-healthy"
  app_names = [
    "secrets-apps",
    "eso-data-apps",
    "monitoring-apps",
    "backups-apps",
    "networking-apps",
    "wireguard-apps",
    "dex-apps",
    "argocd-config-apps",
    "grafana-apps",
    "argo-workflows-apps",
    "terraform-apply-apps",
  ]
  service_account_name = kubernetes_service_account.wait_platform_apps.metadata[0].name

  # Forces a fresh Job whenever ANY watched domain is redeployed, and
  # supplies the implicit Terraform dependency on all of them — see the
  # module's own revision_trigger description. Joining every domain's own
  # revision means a change to any one of them alone is enough to trigger a
  # fresh Job, same "re-run the wait on redeploy" behavior the original
  # single-domain PLATFORM_APPS_REVISION env var had.
  revision_trigger = join(",", [
    helm_release.secrets_apps.metadata.revision,
    helm_release.eso_data_apps.metadata.revision,
    helm_release.monitoring_apps.metadata.revision,
    helm_release.backups_apps.metadata.revision,
    helm_release.networking_apps.metadata.revision,
    helm_release.wireguard_apps.metadata.revision,
    helm_release.dex_apps.metadata.revision,
    helm_release.argocd_config_apps.metadata.revision,
    helm_release.grafana_apps.metadata.revision,
    helm_release.argo_workflows_apps.metadata.revision,
    helm_release.terraform_apply_apps.metadata.revision,
  ])

  depends_on = [
    helm_release.secrets_apps,
    helm_release.eso_data_apps,
    helm_release.monitoring_apps,
    helm_release.backups_apps,
    helm_release.networking_apps,
    helm_release.wireguard_apps,
    helm_release.dex_apps,
    helm_release.argocd_config_apps,
    helm_release.grafana_apps,
    helm_release.argo_workflows_apps,
    helm_release.terraform_apply_apps,
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
