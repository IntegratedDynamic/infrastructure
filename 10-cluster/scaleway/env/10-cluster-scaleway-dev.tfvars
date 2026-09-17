cluster_name = "scaleway-homelab"
node_count   = 2

# This homelab runs on Let's Encrypt STAGING, not prod, as its standing
# state (see var.letsencrypt_staging). Two reasons, both confirmed live:
#  1. gateway/cert-restore restores the scalepack.fr wildcard TLS Secret
#     from the latest Velero backup on every fresh boot -- and every
#     backup taken so far is from a staging-issued cert. cert-manager
#     treats the restored Secret as satisfying the Certificate (right
#     SANs, valid dates) and does NOT re-issue against letsencrypt-prod,
#     so envoy-gateway ends up serving a staging cert regardless of which
#     ClusterIssuer is "active". Running the whole platform on staging
#     keeps ArgoCD/OpenBao's server-side OIDC calls to auth.scalepack.fr
#     trusting the right root (their rootCA / oidc_discovery_ca_pem
#     overrides only kick in when this flag is true) instead of failing
#     "x509: certificate signed by unknown authority".
#  2. This cluster is rebuilt from scratch often enough that LE's prod
#     rate limit (5 duplicate certs/week) is a real risk; staging's
#     limits are far higher.
# Flip to false only alongside a deliberate move to prod certs (fresh
# prod-issued backup, or cert-restore disabled).
letsencrypt_staging = true

# Cross-root state reads — see 00-foundation/scaleway/env/00-foundation-scaleway-dev.tfvars
# for the full bucket list. Keys updated 2026-08-24 (workspace-naming
# refacto) to point at each target root's new prefix/workspace.
backup_scaleway_state_bucket    = "id-terraform-state-03-storage-scaleway"
backup_scaleway_state_key       = "03-storage/scaleway/03-storage-scaleway-dev/terraform.tfstate"
openbao_unseal_aws_state_bucket = "id-terraform-state-02-encryption-aws"
openbao_unseal_aws_state_key    = "02-encryption/aws/02-encryption-aws-dev/terraform.tfstate"
dns_scaleway_state_bucket       = "id-terraform-state-01-iam-workload-scaleway"
dns_scaleway_state_key          = "01-iam/workload/scaleway/01-iam-workload-scaleway-dev/terraform.tfstate"

# infra#113: this homelab's whole platform-apps DAG. See
# 10-cluster/modules/platform-apps-dag/variables.tf's own var.domains for
# the field meanings, and that module's main.tf header comment for why the
# cross-domain wiring below is expressed as needs_crds/needs_secrets/
# needs_backups/needs_dex/needs_networking_controllers/needs_grafana
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

  # ── dex/argocd-config/grafana, extracted from gitops repo (infra#84 follow-up) ──
  #
  # Each of these three domains shares the identical dependency profile on
  # secrets-apps -- but each stays its OWN domain rather than one bundled
  # Application, since argo-workflows-apps below needs to health-wait on
  # dex specifically, not a bundle diluted by argocd-config/grafana's
  # unrelated health.
  dex-apps = {
    value_files   = ["values-dex.yaml"]
    needs_secrets = true
  }

  # needs_secrets here is load-bearing, not defensive:
  # services/platform/argocd-config/config's PostSync restart-hook Job
  # (argocd-config-restart-server) bounces argocd-server so it picks up
  # argocd-oidc-client-secret's now-resolved $-reference (ArgoCD never
  # re-reads a $secretName:key substitution live -- only a real pod restart
  # clears it). Confirmed live (2026-09-14): waiting only for Terraform's
  # own `helm install` to return, not for secrets-apps to actually sync,
  # let the hook fire against a not-yet-existing secret and broke every SSO
  # login for the rest of that cluster's life -- a one-shot PostSync hook
  # has no self-healing the way dex-apps/wireguard-apps' long-running
  # Deployments do.
  argocd-config-apps = {
    value_files   = ["values-argocd-config.yaml"]
    needs_secrets = true
  }

  grafana-apps = {
    value_files   = ["values-grafana.yaml"]
    needs_secrets = true
    needs_backups = true
  }

  # ── argo-workflows, extracted from gitops repo (infra#84 follow-up) ─────
  #
  # argo-workflows/chart eager-dials Dex's OIDC issuer at pod startup and
  # crash-loops if Dex isn't reachable -- a real hard dependency, unlike
  # ESO's self-heal tolerance.
  argo-workflows-apps = {
    value_files   = ["values-argo-workflows.yaml"]
    needs_secrets = true
    needs_dex     = true
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

  # gitops repo's own app-of-apps (now just `demo`, every other domain
  # migrated into the platform-apps domains above). Fits the SAME
  # Application shape (finalizers/project/destination/syncPolicy) even
  # though its source is the gitops repo, not this one, and it's driven
  # entirely by parameters (no valueFiles). No needs_* flags: the final
  # wait-all-domains-healthy gate polls every domain's own Application
  # directly (bootstrap included), so it already subsumes what a dedicated
  # gate would have covered.
  bootstrap = {
    source = "gitops"
    parameters = [
      { name = "env", value = "scaleway" },
    ]
  }
}
