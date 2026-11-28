# Recipe of a "main" cluster: which features it runs and how big it is. Written
# once, shared by every core; what differs between cores is in
# live/core/<core>/wiring.hcl.
#
# These are `inputs`, so a root's own *.auto.tfvars or a -var still overrides them.

inputs = {
  node_count = 2

  # "staging" here (var.letsencrypt_staging / letsencrypt-staging ClusterIssuer)
  # is Let's Encrypt's own ACME environment (vs. letsencrypt-prod's tight rate
  # limits) -- an UNRELATED axis from this homelab also being named
  # "staging" (this homelab's own environment tier, *.staging.scalepack.fr,
  # vs. a future *.prod.scalepack.fr cluster not yet created). Don't conflate
  # the two: a cluster of any tier can run on EITHER ACME environment.
  #
  # A main cluster runs on Let's Encrypt PROD certs (switched 2026-11-17). The
  # ephemeral unit overrides this to true.
  #
  # It used to sit on STAGING for two reasons, neither holds anymore:
  #  1. the cluster was rebuilt (up/down) often enough that LE's prod rate limit
  #     (5 duplicate certs/week) was a real risk -- it is no longer torn down
  #     routinely;
  #  2. gateway/cert-restore restores the wildcard TLS Secret from the latest
  #     Velero backup, and every backup then was staging-issued, so the platform
  #     had to trust the staging root. cert-manager re-issues when the Secret's
  #     issuer differs from the active ClusterIssuer, which is what the flip
  #     relies on.
  # Reason to flip back to true: a burst of same-week rebuilds hitting the rate
  # limit again (and then flip it back once the window passes). Public webhooks
  # (GitHub -> hooks.staging.scalepack.fr) need a publicly trusted cert, which is
  # why this moved.
  letsencrypt_staging = false

  # infra#113: the whole platform-apps DAG of a main cluster. See
  # 10-cluster/modules/platform-apps-dag/variables.tf's own var.domains for
  # the field meanings, and that module's main.tf header comment for why the
  # cross-domain wiring below is expressed as needs_crds/needs_secrets/
  # needs_backups/needs_networking_controllers/needs_grafana
  # instead of a free-form named graph (a real OpenTofu limitation:
  # self-referencing for_each is not expressible, confirmed live 2026-09-17
  # -- not a design preference). crds-apps/secrets-apps/backups-apps/
  # dex-apps/networking-controllers-apps/grafana-apps need no needs_* flags
  # themselves -- they're the six well-known gate domains the module
  # hardcodes by name, never consumers of each other. activeClusterIssuer/
  # hostSuffix (networking-resources-apps), infraRevision (crossplane-apps)
  # and letsEncryptStaging (grafana-apps) are NOT set here -- they're derived
  # from var.letsencrypt_staging/var.env_suffix/the resolved infra revision,
  # so argocd.tf merges them on top of this map before calling the module.
  # Same for every domain's depends_on_ids (a handful of main.tf Secrets/
  # null_resource/config_map no tfvars literal could reference).
  domains = {
    # ── crds-apps, every CRD-only chart across the whole platform ───────────
    #
    # CRD registration needs nothing but the API server reachable, no Secret,
    # no other domain -- a genuine leaf, like every other gate domain.
    crds-apps = {
      value_files = ["values-crds.yaml"]
    }

    # openbao/openbao-init (wave 0), external-secrets (wave 0), secrets-sync
    # (wave 1), every product's ExternalSecret (wave 2). No needs_crds:
    # external-secrets manages its own CRDs, and OpenBao needs no CRD at all --
    # starts in parallel with crds-apps.
    secrets-apps = {
      value_files = ["values-secrets.yaml"]
    }

    # No ESO ExternalSecret in this domain (see argocd.tf's
    # domain_extra_depends_on_ids) -- no ordering dependency on secrets-apps.
    monitoring-apps = {
      value_files = ["values-monitoring.yaml"]
      needs_crds  = true
    }

    # Holds velero (wave 0) AND its two restore hooks cert-restore/
    # grafana-restore (wave 1).
    backups-apps = {
      value_files = ["values-backups.yaml"]
    }

    # Split out of the old combined networking-apps (infra#100) --
    # envoy-gateway/cert-manager consume nothing but crds-apps being
    # Established, not any ExternalSecret, so unlike networking-resources-apps
    # below this domain has no dependency on secrets-apps at all (unlike
    # 10-cluster/kind's own graph -- see that root's own tfvars for the real,
    # kind-only race this dependency closes there).
    networking-controllers-apps = {
      value_files = ["values-networking-controllers.yaml"]
      needs_crds  = true
    }

    # Holds gateway-config/external-dns (wave 0) AND every product's
    # `*-gateway` HTTPRoute chart (wave 1). networking-controllers-apps
    # deliberately stays a SEPARATE domain: Terraform can only gate a
    # domain's creation, not pause mid-sync between two of its own waves, so
    # folding the controllers in would force them to also wait for
    # secrets-apps/backups-apps below for no reason.
    #
    # Gates:
    #  - networking-controllers-apps: gateway-config's ClusterIssuers fail
    #    outright at the API level if cert-manager's webhook isn't
    #    registered and serving yet.
    #  - secrets-apps: gateway-config/external-dns consume
    #    cert-manager-webhook-secret/external-dns-secret, and this is the
    #    single check covering every ExternalSecret's webhook-serving
    #    readiness (plus the externalsecret-cleanup finalizer's
    #    destroy-ordering).
    #  - backups-apps: gateway-config's wildcard TLS Secret restore is wave 1
    #    of backups-apps.
    networking-resources-apps = {
      value_files                  = ["values-networking-resources.yaml"]
      needs_networking_controllers = true
      needs_secrets                = true
      needs_backups                = true
    }

    # wireguard-secret lives in secrets-apps' wave 2 -- wireguard-config just
    # consumes the Secret it materializes. No CRD consumed either -- the same
    # "don't pay for a dependency you don't have" reasoning that keeps OpenBao
    # off crds-apps.
    wireguard-apps = {
      value_files   = ["values-wireguard.yaml"]
      needs_secrets = true
    }

    # KEDA (event-driven autoscaler + HTTP Add-on): ships its own CRDs and needs
    # no Secret, but its chart generates ServiceMonitors (values-scaleway.yaml
    # in gitops), so the monitoring.coreos.com CRDs from crds-apps must be
    # Established first. A GATE (the seventh, see platform-apps-dag/main.tf):
    # bootstrap's `demo` ships an HTTPScaledObject (CRD from the HTTP Add-on)
    # and its first sync would fail if it raced ahead of this domain.
    keda-apps = {
      value_files = ["values-keda.yaml"]
      needs_crds  = true
    }

    # authentik (infra issue #135): the identity provider + forward-auth. Needs its
    # Secret (OpenBao) and Velero: its first wave restores the Postgres volume from
    # the latest snapshot before authentik creates an empty one (see
    # values-sso.yaml for the ordering and why it cannot deadlock). Its
    # configuration is the authentik-managed Workspace in crossplane-apps.
    sso-apps = {
      value_files   = ["values-sso.yaml"]
      needs_secrets = true
      needs_backups = true
    }

    # headscale: the self-hosted Tailscale control server. needs_backups: its first
    # wave restores the data volume before headscale would create an empty one.
    # needs_crds: ServiceMonitor. It also needs authentik to start, which is left
    # to restarts on purpose (see values-headscale.yaml).
    headscale-apps = {
      value_files   = ["values-headscale.yaml"]
      needs_crds    = true
      needs_backups = true
    }

    # ── grafana, extracted from gitops repo (infra#84 follow-up) ──
    #
    # (dex-apps and argocd-config-apps used to sit next to it and are gone with
    # Dex, infra issue #135: argocd-config's only job was a PostSync restart of
    # argocd-server for the Dex-era `$argocd-oidc-client-secret` reference, a
    # secret ArgoCD no longer has since it became a public PKCE client.)
    grafana-apps = {
      value_files   = ["values-grafana.yaml"]
      needs_secrets = true
      needs_backups = true
    }

    # ── crossplane, extracted from gitops repo (infra#84 follow-up; issue #101) ──
    #
    # Crossplane core + upbound/provider-opentofu -- the unattended
    # `tofu apply` loop for 11-secrets/openbao/managed and
    # 12-monitoring/grafana/managed (issue #101). Neither gate below is a hard
    # blocker for the Workspaces to eventually converge -- provider-opentofu
    # retries on its own backoff -- but starting crossplane-apps before either
    # tool is up would just burn reconcile attempts.
    crossplane-apps = {
      value_files   = ["values-crossplane.yaml"]
      needs_secrets = true
      needs_grafana = true
    }

    # gitops repo's PRODUCT app-of-apps (not the cluster bootstrap; now just
    # `demo`, every other domain
    # migrated into the platform-apps domains above). Fits the SAME
    # Application shape (finalizers/project/destination/syncPolicy) even
    # though its source is the gitops repo, not this one, and it's driven
    # entirely by parameters (no valueFiles). Only needs_keda: `demo` ships an
    # InterceptorRoute/ScaledObject (charts/cold-start), whose CRDs come from
    # keda-apps' HTTP Add-on, and a first sync that races ahead of them fails
    # (automated sync does not retry the same commit). The final
    # wait-all-domains-healthy gate does NOT cover this: it only checks health
    # at the end, it does not delay when bootstrap is created. Every other
    # dependency of `demo` (Gateway API CRDs, secrets) is left to ArgoCD's own
    # convergence, as before.
    bootstrap-products = {
      source     = "gitops"
      needs_keda = true
      parameters = [
        { name = "env", value = "scaleway" },
      ]
    }
  }
}
