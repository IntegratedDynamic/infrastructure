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

  # wait_platform_apps_healthy (below) is the real Terraform-enforced
  # prerequisite: bootstrap's Application must not even be created until
  # secrets-apps/monitoring-apps/backups-apps/networking-apps are Healthy —
  # see platform-apps/README.md.
  depends_on = [helm_release.argocd, kubernetes_job_v1.wait_platform_apps_healthy]

  values = [<<EOF
applications:
  bootstrap:
    namespace: argocd
    project: default

    source:
      repoURL: https://github.com/IntegratedDynamic/gitops.git
      targetRevision: ${var.gitops_revision}
      path: bootstrap
      helm:
        parameters:
          - name: env
            value: scaleway
          - name: revision
            value: ${var.gitops_revision}

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

# ── Secrets/monitoring/backups/networking, extracted from gitops repo (infra#84) ───
#
# Four parent Applications (secrets-apps/monitoring-apps/backups-apps/
# networking-apps), each pointing at this repo's own platform-apps/ chart
# (not gitops) for their OWN list of child Applications — see that chart's
# README.md for the full "why" (ArgoCD sync-wave only orders resources
# within one parent Application's own sync, so separate parents is what
# actually lets these domains start in parallel with each other while
# keeping each domain's own real intra-domain ordering, e.g.
# kube-prometheus-stack-crds before kube-prometheus-stack, or
# envoy-gateway/cert-manager before gateway-config). The child Applications' own charts
# (services/platform/openbao/chart, monitoring/chart, ...) are untouched,
# still pulled from the gitops repo, same as before this split — only which
# parent Application claims them as managed resources changed.
resource "helm_release" "argocd_platform_apps" {
  name      = "argocd-platform-apps"
  namespace = "argocd"

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.4"

  depends_on = [
    helm_release.argocd,
    kubernetes_secret.thanos_objstore_config,
    kubernetes_secret.loki_s3_credentials,
    kubernetes_secret.tempo_s3_credentials,
    kubernetes_secret.velero_scaleway_credentials,
  ]

  values = [<<EOF
applications:
  secrets-apps:
    namespace: argocd
    project: default
    source:
      repoURL: https://github.com/IntegratedDynamic/infrastructure.git
      targetRevision: ${var.infra_revision}
      path: 10-cluster/scaleway/platform-apps
      helm:
        valueFiles:
          - values-secrets.yaml
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

  monitoring-apps:
    namespace: argocd
    project: default
    source:
      repoURL: https://github.com/IntegratedDynamic/infrastructure.git
      targetRevision: ${var.infra_revision}
      path: 10-cluster/scaleway/platform-apps
      helm:
        valueFiles:
          - values-monitoring.yaml
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

  backups-apps:
    namespace: argocd
    project: default
    source:
      repoURL: https://github.com/IntegratedDynamic/infrastructure.git
      targetRevision: ${var.infra_revision}
      path: 10-cluster/scaleway/platform-apps
      helm:
        valueFiles:
          - values-backups.yaml
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

  networking-apps:
    namespace: argocd
    project: default
    source:
      repoURL: https://github.com/IntegratedDynamic/infrastructure.git
      targetRevision: ${var.infra_revision}
      path: 10-cluster/scaleway/platform-apps
      helm:
        valueFiles:
          - values-networking.yaml
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

# RBAC for the health-wait Job below — scoped to exactly what it needs
# (read-only on Applications in the argocd namespace), nothing broader.
# Runs as a real in-cluster Job via the Kubernetes API instead of a
# local-exec provisioner: no dependency on a local `kubectl` binary or a
# self-generated kubeconfig, works identically whether this root is applied
# from an admin's machine or CI.
resource "kubernetes_service_account" "wait_platform_apps" {
  metadata {
    name      = "wait-platform-apps-healthy"
    namespace = "argocd"
  }
}

resource "kubernetes_role" "wait_platform_apps" {
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

# The Terraform-enforced prerequisite itself: secrets-apps/monitoring-apps/
# backups-apps/networking-apps must all reach Healthy before bootstrap's own
# Application resource is even created (see that resource's depends_on
# above) — ArgoCD has no native way to express "wait for these independent
# top-level Applications" (sync-wave doesn't cross Application boundaries),
# so this is enforced as a real Terraform apply-order dependency instead.
# `wait_for_completion` makes Terraform itself block on this Job's Complete
# condition — no manual polling of the Job from Terraform's side needed.
# Checks all four Applications together on each iteration (not one at a
# time with its own budget each) since they sync in parallel — a
# sequential per-app budget would only be correct if they synced one after
# another, which is exactly what this whole mechanism exists to avoid.
resource "kubernetes_job_v1" "wait_platform_apps_healthy" {
  metadata {
    name      = "wait-platform-apps-healthy"
    namespace = "argocd"
  }

  spec {
    # Overall budget for all four Applications combined — generous for the
    # same "cluster boot, not steady-state" reason bootstrap's own
    # syncPolicy.retry.limit comment gives. Bumped 900 -> 1800 (2026-08-25):
    # confirmed live on a from-scratch cluster boot that a healthy run can
    # itself take 7+ minutes once ArgoCD/DNS warm-up variance is factored
    # in, and the first-ever timing run hit the original 900s budget
    # outright -- 1800s is a deliberately generous placeholder until this
    # is measured more precisely across a few more boots.
    active_deadline_seconds = 1800
    backoff_limit           = 0

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name" = "wait-platform-apps-healthy"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.wait_platform_apps.metadata[0].name
        restart_policy       = "Never"

        container {
          name = "wait"
          # Same image gitops repo's services/platform/gateway/config
          # (cert-restore-job.yaml) already uses for the identical
          # "kubectl + shell" shape — one fewer image to pull/trust.
          image = "alpine/kubectl:1.35.3"

          command = ["sh", "-c", <<-EOT
            set -eu
            apps="secrets-apps monitoring-apps backups-apps networking-apps"
            while true; do
              all_healthy=true
              for app in $apps; do
                status=$(kubectl get application "$app" -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || true)
                if [ "$status" != "Healthy" ]; then
                  all_healthy=false
                  echo "Application/$app: $${status:-<none yet>}"
                fi
              done
              if [ "$all_healthy" = "true" ]; then
                echo "All platform apps are Healthy."
                exit 0
              fi
              sleep 5
            done
          EOT
          ]

          # Forces a fresh Job (Kubernetes rejects in-place updates to a
          # Job's pod template — Terraform replaces the whole resource
          # instead) whenever the platform apps are actually re-applied,
          # same "re-run the wait on redeploy" behavior the previous
          # null_resource got from its own `triggers` block.
          env {
            name  = "PLATFORM_APPS_REVISION"
            value = helm_release.argocd_platform_apps.metadata.revision
          }
        }
      }
    }
  }

  wait_for_completion = true

  # Must stay above active_deadline_seconds above (30m) -- this is
  # Terraform's own wait on the Job resource itself, so a shorter value
  # here would make Terraform give up before the Job's own budget even
  # runs out.
  timeouts {
    create = "35m"
  }

  depends_on = [
    helm_release.argocd_platform_apps,
    kubernetes_role_binding.wait_platform_apps,
  ]
}
