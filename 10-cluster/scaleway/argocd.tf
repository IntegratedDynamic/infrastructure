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

  cm:
    url: https://argocd.scalepack.fr

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
      # TEMPORARY: apps/gateway-config (gitops repo) runs letsencrypt-staging
      # right now (branch fix/gateway-staging-ca — letsencrypt-prod is
      # rate-limited until 2026-07-26 05:49 UTC), so ArgoCD's own OIDC
      # discovery/token calls to auth.scalepack.fr would otherwise fail
      # TLS verification the same way Grafana's did (confirmed live there:
      # "x509: certificate signed by unknown authority"). rootCA is
      # ArgoCD's native per-provider CA override for exactly this case.
      # Extracted from the live scalepack-fr-wildcard-tls Secret's served
      # chain (intermediate + cross-signed root), same bundle used for
      # Grafana's tls_client_ca and OpenBao's oidc_discovery_ca_pem.
      # Remove once back on letsencrypt-prod.
      rootCA: |
        -----BEGIN CERTIFICATE-----
        MIIFDjCCAvagAwIBAgIQP62QbC8DAdGNbaR7NzBv3jANBgkqhkiG9w0BAQsFADBD
        MQswCQYDVQQGEwJVUzENMAsGA1UEChMESVNSRzElMCMGA1UEAxMcKFNUQUdJTkcp
        IFlvbmRlciBZYW0gUm9vdCBZUjAeFw0yNTA5MDMwMDAwMDBaFw0yODA5MDIyMzU5
        NTlaMEoxCzAJBgNVBAYTAlVTMRYwFAYDVQQKEw1MZXQncyBFbmNyeXB0MSMwIQYD
        VQQDExooU1RBR0lORykgRXJzYXR6IEVtbWVyIFlSMjCCASIwDQYJKoZIhvcNAQEB
        BQADggEPADCCAQoCggEBALVKXXQ+HfIdsroHx2TzhU3yBaocETY0MRoMHnS8CXUd
        X3GYyVh/rHVgbiN3Kl8uBUl9PULcgNL5ltGEaPbQpQ6Ydb3SCAUTkJYySlJRFTdd
        VnreV5Rv+zkcwWiyCVxjT1q10MDHQwIqKzfQqNK0bPn/RTUMgdGREPZsDdHaRjNS
        t3zTECX/UUkeKSGwRqQLmdpmT0cV1XgUnNdCSeZoChX/WGTy5ntWD7ejHUo/KQG5
        bhbD+XZ7Lm7us4Q5eBa10wgF9n7Q5JK/ZzwJ3Hx/o889zV+ZOlxWiQJi2K4E0DM9
        Oj3hPPHW6NEWNjVqvDOWd8WqlgrM06JKWukGgZzzieECAwEAAaOB9jCB8zAOBgNV
        HQ8BAf8EBAMCAYYwEwYDVR0lBAwwCgYIKwYBBQUHAwEwEgYDVR0TAQH/BAgwBgEB
        /wIBADAdBgNVHQ4EFgQURf/2+BQuZ/bfqVTyRaVnwNZqg2wwHwYDVR0jBBgwFoAU
        ULHXmAJQX9syRhtYwWhAciRvSsEwNgYIKwYBBQUHAQEEKjAoMCYGCCsGAQUFBzAC
        hhpodHRwOi8vc3RnLXlyLmkubGVuY3Iub3JnLzATBgNVHSAEDDAKMAgGBmeBDAEC
        ATArBgNVHR8EJDAiMCCgHqAchhpodHRwOi8vc3RnLXlyLmMubGVuY3Iub3JnLzAN
        BgkqhkiG9w0BAQsFAAOCAgEAhUIaqp4M/cqLqKqb5zyG9kJkGYzOWq2YHV558vCK
        CeLDkc12Jlll7u+AqkfkqwnLmqUHolHPQFNdL6HPW+f9lX68Kv4kaznRT7rxqXbX
        xWO5ylgpJibwDKmVt581OcyhleZ8fajL2LfcDbY24ivsWOwlKevbLBV2C+HKS+IM
        yvKxJovnbQsd2NfEiizPfrHXJAqyOv49yYeeE+eorvQHe8HJrNrYVjSs6PI51dbv
        Lac6+SwfiwbtGZqddS7t8IY+IfOksamRe78s4kiA99nLOEGrQXhxNZIryngqL8p8
        FKIi4UIC4Jez5wF8aSS/SG5IhCGbixgSYj/NpttpHOuWQFij54/eaFC8JXgDXafz
        +XXFuuTXpEzQdD0exRnRj5DU0GUR174KagSiYgK2ND0RAPMkwtdOND+2wCN6UC5x
        9fAjsDETMOe0aDAA1MKITiZ27MAxvxIDuAqTcVKYLu8NA37r2oC0k8ucAipMSUxt
        OYQ03+hl+7GCx14j9LYYG3PfVt/qD5wsp6ys2GcJX0GPj2FziTs0FoIb1zrKTD1v
        66xRtYZJIJmFfeSeZf7D0UcD3YA5Mbjmuz/6h43mws2nG/ZHbwPOtZV2N4cbXszu
        fEciE157FGkWTBabn3GeUd2uyMvuhbPKM6UajJ4TyjFBM8AVZyNPFR0IqRLZX64h
        DS4=
        -----END CERTIFICATE-----
        -----BEGIN CERTIFICATE-----
        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
        -----END CERTIFICATE-----

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
      cpu: 1000m
      # Lowered from 2048Mi 2026-08-20: paired with GOMEMLIMIT above instead
      # of just raising this further -- see that env var's own comment.
      memory: "${local.argocd_controller_memory_limit_mib}Mi"

repoServer:
  replicas: 1
  resources:
    requests:
      cpu: 25m
      memory: 192Mi
    limits:
      cpu: 1000m
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

  depends_on = [helm_release.argocd]

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
