# `platform-apps` — secrets/monitoring/backups/networking, extracted from gitops (infra#84)

## Why this exists

Before this split, `gitops` repo's `bootstrap` app-of-apps managed OpenBao,
ESO, monitoring (kube-prometheus-stack/loki/tempo/alloy/otel-collector),
Velero, and cluster networking (envoy-gateway/cert-manager/external-dns/
gateway-config) as its own sequential sync-waves — even though none of
these four domains actually depend on each other, or on anything else in
`bootstrap`'s later waves (dex/product apps). Investigation (2026-08-24)
found these waves among the slowest in a full bootstrap
(`kube-prometheus-stack` ~2m14s to Healthy), each wave paying a further
1-2min gap on top even when the healthcheck poll itself was fast.
Networking was added to the scope a day later (same issue, see infra#84's
comment thread) for the same reason: it's platform-level infra, same as
the first three, and overlaps this repo's own `04-vpn` domain already.

This chart, plus `argocd.tf`'s `argocd_platform_apps` helm_release and
`wait_platform_apps_healthy` null_resource, extracts those four domains
into their own parallel-starting parent Applications, gated as a real
Terraform-enforced prerequisite of `bootstrap` (not a consequence of it).

Every product-specific `*-gateway` HTTPRoute chart (`dex-gateway`,
`grafana-gateway`, `argocd-config-gateway`, `openbao-gateway`,
`argo-workflows-gateway`) stays in `gitops` repo's `bootstrap` — those are
per-product exposure, not shared routing infrastructure, and their own
prerequisite (`networking-apps`' Gateway object) is now ready even earlier
than before.

## Why four separate value files, not one list

ArgoCD's sync-wave annotation only orders resources **within one parent
Application's own sync** — confirmed live in gitops repo's
`bootstrap/README.md` ("Why sync-wave on one Application's own resources,
not an ApplicationSet"). Two independent top-level Applications get zero
ordering between them, automated sync policy or not.

Secrets, monitoring, and networking all still have a real *intra-domain*
ordering requirement inherited from the original bootstrap waves (openbao
before openbao-init sharing a wave is fine — self-heals;
kube-prometheus-stack-crds finishing **before** kube-prometheus-stack starts
is a hard, non-self-healing requirement — see gitops repo's
`bootstrap/README.md` wave 2 for the confirmed-live incident; gateway-config
needing envoy-gateway's AND cert-manager's CRDs to have actually landed
before it can create its `ClusterIssuer`s is the same class of hard
dependency, wave 5 in that same file). Splitting into four separate parent
Applications (`secrets-apps`, `monitoring-apps`, `backups-apps`,
`networking-apps` — see `argocd.tf`) keeps each domain's own proven
sync-wave ordering intact while giving up nothing: the four parents
themselves have no ordering *between* them, which is exactly the "start in
parallel" requirement.

`networking-apps` additionally has a *soft* cross-domain dependency on
`secrets-apps`: `cert-manager-webhook-secret`/`external-dns-secret` are
still ESO `ExternalSecret`s (see "The secret-delivery pattern" below), so
they need OpenBao+ESO reachable to resolve. This is deliberately left
ungated — same "brief race, self-heals via ESO's own refreshInterval"
tolerance every other `*-secret` chart in `gitops` repo's `bootstrap`
already accepts, not a new risk this split introduces. `gateway-config`'s
dependency on Velero (its cert-restore PreSync hook) is similarly left
ungated on purpose — that hook already queries the `velero` namespace's
`Backup`/`Restore` objects directly via the Kubernetes API and fails open
if none shows up within its own budget, independent of which anything
ArgoCD-side is Healthy (see `gitops` repo's
`services/platform/gateway/config/README.md`, and infra#84's issue
comments for why an ArgoCD-sync-wave-based attempt at this exact
dependency was tried and abandoned before this split even existed).

## Why the cross-domain "finish before bootstrap" gate is Terraform, not ArgoCD

Same reasoning as above, the other direction: there is no ArgoCD-native way
to say "don't even start syncing Application X until Applications A/B/C are
Healthy" when A/B/C/X are independent top-level Applications. `argocd.tf`'s
`null_resource.wait_platform_apps_healthy` polls the four parent
Applications' `.status.health.status` via `kubectl` (using a
Terraform-generated kubeconfig, not `~/.kube/config` — self-contained,
works whether or not `var.update_kubeconfig` ran) before the `bootstrap`
Application resource is created at all. This is a real `depends_on`
enforced by Terraform's own apply order, not a sync-wave — the only
mechanism that can span independent top-level Applications.

## Namespace decision (infra#84's open question)

Namespaces are **not** wholesale extracted to Terraform. `monitoring` and
`velero` get Terraform-managed `kubernetes_namespace` resources in this
root's `main.tf`, same pattern `openbao` already used before this split —
but *only* because Terraform now writes Kubernetes Secrets into them ahead
of ArgoCD's own sync (see below), and a Secret can't be created before its
namespace exists. `external-secrets` and `secrets-sync` get no such
treatment — nothing Terraform-side writes into those namespaces, so they
stay `CreateNamespace=true`-created by their own Application, same as every
other app in this repo.

The issue's original hypothesis (Velero might be slow because Argo creates
its backup-target namespaces one at a time across waves) was never verified
either way — moot here, since `velero`'s namespace ends up Terraform-managed
regardless, for the secret-ordering reason above, not a startup-speed one.

`networking-apps`' namespaces (`cert-manager`, `envoy-gateway-system`,
`gateway`, `external-dns`) get no such treatment either — same as
`external-secrets`/`secrets-sync` above, nothing Terraform-side writes into
them (this domain keeps using ESO, see below), so they stay
`CreateNamespace=true`-created by their own Application.

## The secret-delivery pattern (infra#84's other open question)

For the four credentials Terraform already originates (thanos/loki/tempo/
velero Object Storage access keys — see `03-storage/scaleway`), the old
path was Terraform → OpenBao KV (`11-secrets/openbao/managed`) → ESO
`ExternalSecret` → Kubernetes Secret. That's unchanged in its first half:
`11-secrets/openbao/managed`'s `vault_kv_secret_v2` resources still write
these into OpenBao, which stays the audited single source of truth for the
credential values (per the issue's own comment thread). What's gone is the
second half — ESO is no longer in the loop for these four. This root's
`main.tf` now writes the Kubernetes Secret directly
(`thanos-objstore-config`, `loki-s3-credentials`, `tempo-s3-credentials`,
`velero-scaleway-credentials`), reading the same
`data.terraform_remote_state.backup_scaleway` outputs
`11-secrets/openbao/managed` already reads — no new cross-root wiring, and
one fewer async hop between "Terraform knows the credential" and "the pod
that needs it can read it". The four gitops-repo charts that used to do
this via `ExternalSecret` (`services/platform/velero/secret`,
`monitoring/thanos-secret`, `monitoring/loki-secret`,
`monitoring/tempo-secret`) were deleted — see gitops repo PR for infra#84.

This is deliberately narrower than the issue's original "pre-populate +
`lifecycle { ignore_changes }`" proposal: since these four secrets are
*entirely* Terraform-owned now (Terraform is the only writer, ESO never
touches them), there's no OpenBao/ESO reconciler to race or ignore —
`ignore_changes` would have nothing to protect against here. Every other
product's own secret (dex-secret, external-dns-secret, grafana-secret, ...)
is untouched and stays exactly on the OpenBao+ESO path it was on before —
**including `networking-apps`' own `cert-manager-webhook-secret` and
`external-dns-secret`**, added to this chart later (infra#84's comment
thread). Terraform doesn't originate the Scaleway Domains/DNS API
credential either of those materialize (unlike thanos/loki/tempo/velero's
Object Storage keys, which come straight from this same repo's
`03-storage/scaleway`) — there's nothing to gain by bypassing ESO for a
credential Terraform has no more direct a line to than ESO already does, so
this domain deliberately keeps the existing mechanism rather than applying
the direct-`kubernetes_secret` pattern uniformly.
