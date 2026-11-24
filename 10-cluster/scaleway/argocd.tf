# infra#113: this homelab's whole platform-apps DAG lives as DATA in
# env/10-cluster-scaleway-staging.tfvars (var.domains, see
# modules/platform-apps-dag/variables.tf's own description) -- this file now
# only holds what's genuinely environment-specific and can't be expressed as
# tfvars: ArgoCD's own bootstrap (OIDC login through authentik, public URL, RBAC
# policy), the git-existence-probing DevX trick that resolves
# var.gitops_revision/var.infra_revision at apply time, and the handful of
# dynamic parameter/dependency values (main.tf's own Secrets,
# letsencrypt_staging/env_suffix-derived parameters) merged onto var.domains
# right before the single module.platform_apps call. See that module's
# main.tf for why the per-domain module deliberately does NOT also own its
# wait gate (soft vs. hard cross-domain dependencies would otherwise
# collapse into always-hard), and 10-cluster/platform-apps/README.md for the
# platform-wide DAG this wiring encodes.

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

# var.infra_revision's own comment: when left unset, auto-detect the
# CURRENT LOCAL branch of THIS repo instead of hardcoding "main" -- a human
# running `tofu plan/apply` locally from a feature branch then gets the
# "override on your own branch" DevX trick for free. `git rev-parse` works
# from this module's own directory (10-cluster/scaleway), no `-C`/cd needed,
# since it's still inside the repo working tree. Only run when the var is
# actually unset -- an explicit override (CI's generated tfvars, or a human
# deliberately testing a different branch) skips this entirely.
data "external" "local_infra_branch" {
  count = var.infra_revision == null ? 1 : 0

  program = ["sh", "-c", <<-EOT
    echo "{\"branch\": \"$(git rev-parse --abbrev-ref HEAD)\"}"
  EOT
  ]
}

locals {
  # Falls back to "main" if even the git command above somehow produced
  # nothing usable (try() guards a data source that errored outright, not
  # just a missing branch -- that's the existence probe's job below).
  requested_infra_revision = coalesce(var.infra_revision, try(data.external.local_infra_branch[0].result.branch, "main"))
}

data "external" "infra_revision_exists" {
  count = local.requested_infra_revision != "main" ? 1 : 0

  program = ["sh", "-c", <<-EOT
    if git ls-remote --exit-code --heads ${local.platform_apps_source_repo} "${local.requested_infra_revision}" >/dev/null 2>&1; then
      echo '{"exists": "true"}'
    else
      echo '{"exists": "false"}'
    fi
  EOT
  ]
}

locals {
  # The revision every targetRevision/gitRef below actually uses -- var.
  # gitops_revision/local.requested_infra_revision verbatim when that branch
  # exists upstream (or when it's already "main", never probed), "main"
  # otherwise. `--heads` only checks branches, matching these vars'
  # documented "override on your own branch" purpose -- a tag or bare commit
  # SHA would (incorrectly) fall back to "main" too, but neither is a
  # supported value for either variable today.
  effective_gitops_revision = try(data.external.gitops_revision_exists[0].result.exists, "true") == "true" ? var.gitops_revision : "main"
  effective_infra_revision  = try(data.external.infra_revision_exists[0].result.exists, "true") == "true" ? local.requested_infra_revision : "main"

  # var.letsencrypt_staging (see that variable's own comment): which
  # ClusterIssuer gateway-config's Gateway actually uses. Threaded into
  # networking-resources-apps' own Application parameters below (merged
  # onto var.domains, since it's derived from a variable, not literal
  # tfvars data).
  active_cluster_issuer = var.letsencrypt_staging ? "letsencrypt-staging" : "letsencrypt-prod"

  # var.env_suffix (see that variable's own comment) -- threaded into
  # networking-resources-apps' own Application parameters below as
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
        # var.env_suffix/local.host_suffix (see that variable's own comment
        # for the full "why"): confirmed live (infra#113 SSO-fix,
        # 2026-09-17) that this had NEVER been threaded through here despite
        # every *-gateway chart's own hostname already supporting it --
        # ArgoCD kept generating OAuth callback URLs against the UNSUFFIXED
        # https://argocd.staging.scalepack.fr even on an ephemeral cluster actually
        # reachable at https://argocd-pr-123.staging.scalepack.fr, so the OIDC
        # redirect_uri never matched what the IdP's client whitelisted (it was
        # Dex's static client then) -- SSO login failed outright. See
        # oidc.config.issuer below for the other half of this fix.
        url: https://argocd${local.host_suffix}.${var.domain}

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

        # Local admin login is redundant now that OIDC via authentik is working —
        # one login path, no separate password to rotate/leak.
        admin.enabled: "false"

        # Native OIDC against authentik (14-sso/managed/oidc.tf in this repo,
        # client `argocd`; was the shared Dex) instead of the chart's built-in
        # Dex (disabled by module.argocd_base_values) — one IdP for the whole
        # platform, one place who may log in is defined (GitHub org/team ->
        # authentik groups, see 14-sso/managed/github.tf).
        oidc.config: |
          name: authentik
          # var.env_suffix/local.host_suffix -- must match authentik's OWN
          # gateway hostname (gitops repo's services/platform/authentik/gateway
          # builds "sso" + hostSuffix + ".staging.scalepack.fr"). The issuer is
          # PER APPLICATION in authentik: .../application/o/<slug>/ (slug
          # `argocd`), with the trailing slash -- it must equal the `iss` claim
          # and the discovery document's issuer exactly.
          issuer: https://sso${local.host_suffix}.${var.domain}/application/o/argocd/
          clientID: argocd
          # PUBLIC client, no clientSecret: one authentik provider serves both
          # the web UI and `argocd login --sso` (the CLI then uses this same
          # clientID, cliClientID omitted), PKCE protecting the code exchange.
          # A separate CLI client cannot work: authentik's issuer is per
          # application, so a CLI client's tokens carry another `iss` and
          # argocd-server rejects them ("id token issued by a different
          # provider", seen live). redirect URIs (14-sso/managed/oidc.tf):
          # https://argocd.<domain>/auth/callback and
          # http://localhost:8085/auth/callback.
          enablePKCEAuthentication: true
          # `profile` carries the `groups` claim in authentik (no separate
          # `groups` scope; an unknown scope is silently dropped).
          requestedScopes:
            - openid
            - profile
            - email
    %{if var.letsencrypt_staging~}
          # var.letsencrypt_staging (see that variable's own comment): ArgoCD's
          # native per-provider CA override for OIDC discovery/token calls to
          # https://sso.staging.scalepack.fr -- no pod/volume/init-container change
          # needed, and doesn't touch trust for any other legitimate HTTPS call
          # this pod makes (e.g. GitHub for git repos).
          # https://argo-cd.readthedocs.io/en/stable/operator-manual/user-management/#configuring-a-custom-root-ca-certificate-for-communicating-with-the-oidc-provider
          rootCA: |
            ${indent(8, trimspace(local.letsencrypt_staging_ca_pem))}
    %{endif~}

      rbac:
        policy.csv: |
          g, platform-admins, role:admin
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
      # whose RollingSync strategy groups Velero/external-dns/Grafana after
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

# ── Dynamic values var.domains can't express itself, merged on top ─────────
#
# A tfvars value is static; these can't be. depends_on_ids references a real
# Terraform resource (main.tf's own Secrets/null_resource/config_map) -- a
# literal string in tfvars couldn't do that. The three extra parameter sets
# are derived from variables (var.letsencrypt_staging/var.env_suffix) or
# from the git-existence-probed revision above, not literal per-environment
# text.
locals {
  domain_extra_parameters = {
    # var.letsencrypt_staging/var.env_suffix -- picked up by gateway-config's
    # and every *-gateway chart's own valueParams entry in
    # values-networking-resources.yaml.
    networking-resources-apps = [
      { name = "activeClusterIssuer", value = local.active_cluster_issuer },
      { name = "hostSuffix", value = local.host_suffix },
    ]
    # infra#76: threads THIS repo's own revision through so
    # crossplane-config's gitRefParam (values-crossplane.yaml) overrides its
    # chart's `gitRef: main` default -- every Workspace's git module `?ref=`
    # then follows the infra branch under test.
    crossplane-apps = [
      { name = "infraRevision", value = local.effective_infra_revision },
      # authentik-managed Workspace (14-sso/managed): its hostnames carry the
      # same per-cluster suffix as the *-gateway charts.
      { name = "hostSuffix", value = local.host_suffix },
    ]
    grafana-apps = [
      { name = "letsEncryptStaging", value = tostring(var.letsencrypt_staging) },
    ]
  }

  domain_extra_depends_on_ids = {
    # This Application manages the openbao child Application and writes
    # into the openbao namespace, so it must still be guaranteed to finish
    # its own cascade-delete before kubernetes_namespace.openbao's destroy
    # (confirmed live 2026-08-25: ArgoCD's openbao Application was
    # mid-retry writing into that namespace while Terraform deleted it
    # directly).
    secrets-apps = [
      kubernetes_secret.scaleway_s3_credentials.id,
      kubernetes_secret.openbao_unseal_aws.id,
    ]
    # No ESO ExternalSecret in this domain (thanos/loki/tempo credentials
    # are Terraform-originated Secrets) -- no ordering dependency on
    # secrets-apps needed, only on these three existing.
    monitoring-apps = [
      kubernetes_secret.thanos_objstore_config.id,
      kubernetes_secret.loki_s3_credentials.id,
      kubernetes_secret.tempo_s3_credentials.id,
    ]
    # null_resource.velero_namespace_predelete_cleanup stays listed here for
    # the DESTROY direction: "A depends_on B" means A destroys before B, so
    # this makes this release destroy (and Velero's controller die) BEFORE
    # that cleanup's local-exec runs -- see that resource's own comment in
    # main.tf for the two earlier, wrong ordering attempts.
    backups-apps = [
      kubernetes_secret.velero_scaleway_credentials.id,
      null_resource.velero_namespace_predelete_cleanup.id,
    ]
    # Referencing a count-based resource directly (no index/splat) depends
    # on ALL of its instances -- zero of them when var.letsencrypt_staging
    # is false, so this is a no-op in that case, not an error.
    grafana-apps = var.letsencrypt_staging ? [kubernetes_config_map.letsencrypt_staging_ca_monitoring[0].id] : []
  }

  domains = {
    for key, d in var.domains : key => merge(d, {
      parameters     = concat(d.parameters, lookup(local.domain_extra_parameters, key, []))
      depends_on_ids = concat(d.depends_on_ids, lookup(local.domain_extra_depends_on_ids, key, []))
    })
  }
}

module "platform_apps" {
  source = "../modules/platform-apps-dag"

  domains = local.domains

  infra_revision           = local.effective_infra_revision
  gitops_revision          = local.effective_gitops_revision
  gitops_source_repo       = local.gitops_source_repo
  wait_all_domains_healthy = var.wait_all_domains_healthy

  depends_on = [helm_release.argocd]
}
