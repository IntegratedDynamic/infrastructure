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
own TLS-secret restore from Velero, and `grafana`'s own PVC restore, both
moved out (2026-08-27) to a dedicated `restore-apps` domain
(`values-restore.yaml`) with a REAL Terraform-enforced wait
(`module.wait_restore_healthy`, gated itself on `module.wait_backups_healthy`)
— replacing the "PreSync hook on the consumer chart itself, fails open"
design each used to carry independently. See `gitops` repo's
`services/platform/gateway/cert-restore/README.md` for the full history,
including why a plain ArgoCD-sync-wave-based attempt at this exact
dependency (`services/platform/velero/init`, 2026-07-29) was tried and
abandoned before PreSync hooks became the interim fix this now replaces.

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

## Finishing the migration + generalizing the finalizer-race fix (infra#84 follow-up, 2026-08-25)

The four domains above left one known bug: `networking-apps`' own
`cert-manager-webhook-secret`/`external-dns-secret` are ESO
`ExternalSecret`s, carrying a `externalsecrets.external-secrets.io/externalsecret-cleanup`
finalizer that only ESO's own controller (`secrets-apps` domain) ever
removes. Since `secrets-apps` and `networking-apps` were two keys of the
*same* `helm_release.argocd_platform_apps`, Helm tore both down in parallel
on `destroy` with no ordering between them — ESO's pod could die before it
ever processed this finalizer removal, stranding the object (confirmed live
2026-08-25, previously required a manual `kubectl patch`).

This follow-up did two things at once: finished migrating every remaining
`gitops` repo `bootstrap` app into this same Terraform-managed pattern (so
only `demo` is left there), and fixed the finalizer race structurally in a
way that covers every domain this added, not just `networking-apps`.

**Every domain is now its own `helm_release`**, not a shared one. This is
the mechanical prerequisite for everything below: Helm gives no ordering
guarantee across sibling resources of one release (which is exactly what
let `secrets-apps`/`networking-apps` race each other's teardown), but
Terraform's own `depends_on` between separate `helm_release` resources is a
real graph edge — "A depends_on B" means A is created after B and destroyed
before B, so a domain listed in a `depends_on` is *guaranteed* to still be
alive throughout everything that depends on it.

**Every `ExternalSecret` across every domain now lives in one dedicated
`eso-data-apps` domain**, instead of being bundled into each product's own
domain — `dex-secret`, `grafana-secret`, `wireguard-secret`,
`argo-workflows-secret`, `argocd-config-secret` (split out of
`services/platform/argocd-config/config`, gitops repo, same "mixed chart
split in two" treatment `bootstrap/README.md` documents for `dex`/`grafana`),
and the two that used to live directly in `networking-apps`
(`cert-manager-webhook-secret`/`external-dns-secret`). `eso_data_apps`
`depends_on = [helm_release.secrets_apps]` — the ONE edge that fixes the
finalizer race for every consumer at once: this release (and every
`ExternalSecret` it owns) is guaranteed to finish destroying before
`secrets-apps` — and therefore ESO's own controller — even starts tearing
down. Every product domain that consumes one of these secrets just
`depends_on = [helm_release.eso_data_apps]` instead of reasoning about ESO's
own lifecycle directly.

**The two ordering mechanisms are deliberately different, and shouldn't be
conflated:**
1. Raw `depends_on` between `helm_release` resources (used by `eso-data-apps`
   → `secrets-apps`, and by every product domain → `eso-data-apps`) only
   fixes *destroy* ordering — Helm apply itself is fast, so this doesn't
   slow down startup, and ESO's own `refreshInterval` self-heals if a
   consumer briefly starts before its secret exists (the same tolerance
   every ESO consumer already accepted before this split).
2. `kubernetes_job_v1` health-wait gates (the `wait_platform_apps_healthy`
   pattern this repo already had, now factored into the
   `modules/wait-argocd-apps-healthy` module — see that module's own
   comment) are used only where a real hard, non-self-healing dependency
   exists: CRD registration, an eager OIDC dial at pod startup, a live HTTP
   API call. These genuinely delay creation of the dependent domain until
   the upstream one reports `Synced` + `Healthy`.

**The resulting DAG**, tier by tier (superseded by "Generalizing the CRD →
controller → resource → app graph platform-wide" below, which is the
current authoritative tier list — kept here for the historical shape this
generalization built on):

- **Tier 0** (parallel, unchanged): `secrets-apps`, `monitoring-apps`,
  `backups-apps`. `eso-data-apps` sits right after `secrets-apps` — as of
  2026-08-26 a real health-wait (`module.wait_secrets_healthy`), not just
  `depends_on`. Confirmed live: a raw `depends_on` let `eso-data-apps` get
  created and attempt its sync before `secrets-apps`' own `external-secrets`
  chart (wave 1) had actually registered the `external-secrets.io` CRD,
  failing outright ("Make sure the CRD is installed") — a hard,
  non-self-healing sync failure at the API level, not the soft
  "briefly races, self-heals via ESO's own refreshInterval" tolerance
  mechanism 1 above describes (that tolerance only ever covered the
  Secret's own reconcile lag, never the CRD not existing yet).
- **Tier 1** (`depends_on = [eso_data_apps]` only, as of 2026-08-26 — see
  "Decoupling gateway routes from wait_networking_healthy" below for why
  none of these carry a direct `wait_networking_healthy` dependency
  anymore): `networking-apps` (still gains its own eso-data-apps
  dependency, even though it no longer owns an ExternalSecret itself —
  kept for create-order tidiness, not a correctness requirement),
  `wireguard-apps`, `gateways-apps` (see below), `dex-apps`,
  `argocd-config-apps`, `grafana-apps`. `dex-apps` stayed its own domain
  rather than bundled with `argocd-config-apps`/`grafana-apps` (which share
  its exact dependency profile) specifically so Tier 2's wait-gate on "is
  Dex ready" isn't diluted by unrelated apps' health. `grafana-apps` stayed
  out of `monitoring-apps` for the mirror-image reason: folding it in would
  force `kube-prometheus-stack`/`loki`/`tempo` (genuinely independent of
  `networking-apps`) to also wait on networking's CRDs. `grafana-apps` now
  also carries `module.wait_restore_healthy` (2026-08-27) — `grafana`'s own
  PVC restore moved out to the `restore-apps` domain, see that section
  above.
  `gateways-apps` (`depends_on = [eso_data_apps, module.wait_networking_healthy]`)
  holds every `*-gateway` HTTPRoute chart that USED TO live inside
  dex-apps/grafana-apps/argocd-config-apps/argo-workflows-apps themselves —
  see the dedicated section below.
- **Tier 2** (`depends_on = [module.wait_dex_healthy]`): `argo-workflows-apps`
  — `argo-workflows/chart` eager-dials Dex's OIDC issuer at pod startup and
  crash-loops if Dex isn't reachable, a real hard dependency unlike ESO's
  self-heal tolerance. Its own `HTTPRoute` no longer lives in this domain
  (moved to `gateways-apps`, same as every other Tier-1/Tier-2 product) and
  never needed a networking-apps edge of its own in the first place.
- **Tier 3** (`depends_on = [module.wait_argo_workflows_and_grafana_healthy]`):
  `terraform-apply-apps` — its `grafana-managed` root's preflight calls
  Grafana's live HTTP API directly, and its PostSync
  `initial-run-workflow` hook needs `argo-workflows`' own
  `WorkflowTemplate`/CRDs already installed.
- **Final gate**: `module.wait_all_domains_healthy` (renamed from
  `wait_platform_apps_healthy` — same resource in spirit, just checking
  every domain now, not the original four) still gates `bootstrap`'s own
  Application creation, same as before this follow-up — `bootstrap` now
  only manages `demo`.

`openbao-gateway` moved into `networking-apps` itself (not its own domain):
it's a bare `HTTPRoute` with no `ExternalSecret` and no other dependency,
and `networking-apps` already owns the Gateway API CRDs it needs — no
reason to pay for a whole extra domain (release + wait-gate) for one
HTTPRoute. `argocd-config-monitoring` (a `PrometheusRule`) moved into
`monitoring-apps` itself for the identical reason — its only real
dependency is that domain's own `kube-prometheus-stack-crds`, nothing
`argocd-config`-related despite the name it inherited from its `chartPath`.

## Decoupling gateway routes from `wait_networking_healthy` (2026-08-26)

Investigating cluster-startup timing (prompted by the `node_count=1`
homelab change, infra branch `chore/scaleway-node-count-1`) turned up a
second, unrelated bottleneck: `dex-apps`, `grafana-apps`, and
`argocd-config-apps` each used to bundle their product (wave 0) together
with their own `*-gateway` HTTPRoute-only chart (wave 1) in ONE parent
Application — the same "app of apps" shape `argocd.tf`'s
`resource.customizations.health.argoproj.io_Application` recurses into.
That recursive health check means a parent Application's own `.status.health`
is the aggregate of every nested child it manages — so `dex-apps` as a
whole couldn't go Healthy until `dex-gateway`'s HTTPRoute was Accepted,
which needs `networking-apps`' Gateway API CRDs, even though `dex` (the
chart) has zero Gateway API objects of its own. Confirmed by inspecting
every product chart directly: `dex/chart`, `grafana-chart`, and
`argocd-config/config` render only plain Deployments/Services/ConfigMaps/
RBAC — no `HTTPRoute`, no `cert-manager.io` object, nothing
`networking-apps`-shaped. The consumers that actually cared about these
three domains' health already talked to the product over an in-cluster
Service, never through the public route: `argo-workflows/chart` dials Dex
at `http://dex.gateway.svc:5556` (see `values-argo-workflows.yaml`), and
`12-monitoring/grafana/managed`'s Terraform provider talks to Grafana at
`http://grafana.monitoring.svc:80/` by default. Same story one level up:
`argo-workflows-apps` bundled `argo-workflows-gateway` the same way, and
nothing downstream (`terraform-apply-apps`, via
`module.wait_argo_workflows_and_grafana_healthy`) needed that HTTPRoute
either.

Measured live (2026-08-25/26, two full bootstraps): `wait_networking_healthy`
alone routinely takes 5-6 minutes. Before this change, that entire duration
was dead time for `dex-apps`/`grafana-apps`/`argocd-config-apps` — they
couldn't even be *created* until it finished (`argocd.tf`'s
`depends_on = [module.wait_networking_healthy]`), despite Dex itself
converging in about a minute once its Application exists (confirmed via
`wait_dex_healthy`'s own 45s-1m11s observed duration across both runs).

**The fix**: every `*-gateway` HTTPRoute-only chart (`dex-gateway`,
`grafana-gateway`, `argocd-config-gateway`, `argo-workflows-gateway`) moved
into one new shared domain, `gateways-apps` (`values-gateways.yaml`,
`argocd.tf`'s `helm_release.gateways_apps`) — the only domain that still
carries a direct `depends_on = [module.wait_networking_healthy]` for this
reason. No interdependency between the four charts, same "rides along"
shape `openbao-gateway` already uses inside `values-networking.yaml`.
`dex-apps`/`grafana-apps`/`argocd-config-apps`/`argo-workflows-apps` now
depend on `eso-data-apps` only (plus `argo-workflows-apps`' own
`wait_dex_healthy`, unaffected by this change) — each can start syncing its
product the moment its own `*-secret` exists, in parallel with
`networking-apps`' multi-minute convergence, instead of serially after it.
`module.wait_dex_healthy` and `module.wait_argo_workflows_and_grafana_healthy`
are unaffected mechanically (still check `dex-apps`/`grafana-apps` by
name) but now converge faster in practice, since the Application they
watch is no longer artificially held back by an unrelated sibling chart.
`gateways-apps` was added to `module.wait_all_domains_healthy`'s
`app_names` list, same as every other domain.

Re-measured end-to-end (2026-08-26, live fresh bootstrap): confirmed —
`wait_dex_healthy` and `wait_argo_workflows_and_grafana_healthy` dropped to
9s and 16s respectively (from a 45s-3m5s range across prior baselines),
both completing while `wait_networking_healthy` was still running. Total
`tofu apply` came in at 12m23s versus 16m41s/18m6s baselines — a
26-32% cut, matching the prediction above.

## One CRDs domain for the whole platform (2026-08-26)

While re-measuring the change above, live digging into WHY
`wait_networking_healthy` is sometimes 5.5min and sometimes 10+min turned
up a second, unrelated race: `cert-manager`'s controller checks for the
Gateway API CRDs at startup (`ExperimentalGatewayAPISupport`) and
crash-loops if they're not registered yet — confirmed live via exact
timestamps, it crash-looped 4 times in a row sharing a wave with
`envoy-gateway` (the thing that installs those CRDs), and even once the
CRDs were genuinely `Established`, sat out another ~40s of
already-accumulated kubelet `CrashLoopBackOff` penalty before actually
starting. This tax lands on every boot (same-wave siblings start together,
not as an edge case), and is the best lead found for why
`wait_networking_healthy`'s duration varies: each crash risks pushing
`networking-apps`' own ArgoCD-level sync into an extra retry, and each
retry carries its own separate, growing backoff on top of kubelet's.

The fix generalizes past this one race. `kube-prometheus-stack-crds`
already lived as its own earlier-wave Application *inside*
`monitoring-apps` (since 2026-08-13, for the exact same class of problem —
see gitops repo's `bootstrap/README.md` wave 2's own confirmed-live
incident). That per-domain shape only protects the ONE domain it's nested
in; it does nothing for a different domain that happens to need the same
CRD, and does nothing to stop two *unrelated* CRD-installing siblings
(`envoy-gateway`/`cert-manager`) from racing each other. So instead of
adding a second nested `gateway-api-crds` Application inside
`networking-apps` (the first attempt, briefly shipped, then superseded),
every CRD-only chart across the whole platform was pulled into one new
top-level domain, `crds-apps` (`values-crds.yaml` — currently
`kube-prometheus-stack-crds` + the new `gateway-api-crds`, vendoring
envoyproxy's standalone `gateway-crds-helm` chart, see gitops repo PR #54).

`argocd.tf`'s `module.wait_crds_healthy` gates it as a real Terraform
prerequisite of **every** Tier-0 domain (`secrets-apps`, `monitoring-apps`,
`backups-apps`, `networking-apps`, `wireguard-apps`) — none of them is even
*created* until `crds-apps` is Synced+Healthy. Concretely this means:
`envoy-gateway`/`cert-manager` (+ its webhook) go back to sharing one wave
inside `networking-apps` (`skipCrds: true` on `envoy-gateway`, so it
doesn't also try to install its own bundled copy and fight `crds-apps` for
ownership), and `kube-prometheus-stack` does the same inside
`monitoring-apps` — both collapse from two waves back to one, since the
CRD-availability race that justified the earlier wave split no longer
exists anywhere in the platform. `crds-apps` itself needs nothing but
`helm_release.argocd` — CRD registration is fast (no controller pod to wait
on, just the `Established` condition), so this trades a small, one-time
upfront serial wait for eliminating the race everywhere at once rather than
patching it one domain at a time as it's discovered.

Not yet re-measured end-to-end against this specific consolidation.

## Generalizing the CRD → controller → resource → app graph platform-wide (2026-08-26/27)

infra#100 stopped at the two CRD sets that had already raced live (Gateway
API, Prometheus-operator) and called cert-manager's/external-secrets'/
velero's/argo-workflows' own bundled CRDs "out of scope" — no confirmed
cross-release race existed for them *yet*. This round generalizes past
that: instead of fixing CRD races as they're found, the shape of this
chart + `argocd.tf` now encodes the real Kubernetes dependency graph (CRD →
controller → CRD-dependent resource → app) for every CRD on the platform,
bar one deliberate, named exception — so a future addition can't silently
reintroduce the kind of hidden race `gateway-api-crds` fixed. `domain`
stays a human/reading grouping (this file's own sections); the actual
gates (`depends_on`, `wait-argocd-apps-healthy` modules) are driven purely
by what a component genuinely needs, never by "which domain it happens to
share a `values-*.yaml` with".

**`crds-apps` gained `cert-manager-crds`.** (gitops repo's
`services/platform/cert-manager/crds`) is a `helm template`-rendered,
version-pinned copy of that controller chart's own CRD templates — it ships
its CRDs as a plain Helm template gated by a value (`crds.enabled`), not
Helm's native `crds/` folder, so there's no upstream "CRDs-only" package to
depend on the way `gateway-crds-helm`/`prometheus-operator-crds` provide;
this repo instead vendors a static, resolved copy and re-vendors it
whenever the controller chart's own dependency version bumps. Its own
competing copy is disabled (`crds.enabled: false`) so only one Application
ever owns each CRD object.

**`external-secrets-crds`/`velero-crds` were extracted here too on
2026-08-26/27, then REVERTED 2026-08-27**: live-testing the
`letsencrypt_staging` flag surfaced how much `crds-apps`' own convergence
time (confirmed live: ~8.5min for `wait-crds-healthy` on a full CRD set)
was costing `secrets-apps`/`backups-apps`, neither of which actually shared
a CRD-installation race with any OTHER domain the way `envoy-gateway`/
`cert-manager` did. Both charts manage their own CRDs again
(`external-secrets`'s `installCRDs` back to its chart default, `velero`'s
`skipCrds: true` dropped) and no longer wait on `crds-apps` at all —
`values-secrets.yaml`'s `external-secrets` (wave 0) → `secrets-sync`
(wave 1) split is the accepted trade-off instead: ordering within that one
domain via ArgoCD's own intra-Application wave-gating (a native, reliable
guarantee — unlike the cross-Application ordering `module.wait_*_healthy`
gates exist to fix), not a platform-wide one.

**argo-workflows' CRDs are the one deliberate exception**, documented on
its own `Chart.yaml` instead of silently absent: they're installed via a
Helm hook Job (`templates/crds-install-job.yaml` applying raw manifests
from `files/crds/minimal/`) — a workaround for CRD sizes that exceed what a
plain templated manifest or native `crds/` folder can carry, not a
mechanism this repo's other CRD-only charts can trivially mirror. There is
no active cross-release race to fix (the Job runs pre-controller, ordered
by its own hook weight, entirely within `argo-workflows-apps`' own sync) —
extracting it would be vendoring a Job-based installer for a purely
hygienic win. Revisit only if a real race is ever observed live.

**`standalone-apps` is new** (`values-standalone.yaml`, `argocd.tf`'s
`helm_release.standalone_apps`) — `openbao`/`openbao-init`, moved OUT of
`secrets-apps`, gated on nothing but `helm_release.argocd` (+ their own
Terraform-written Secrets). Verified during this generalization: these two
are the *only* components on the whole platform needing neither a CRD nor
an ExternalSecret — every other component needs at least one of `crds-apps`
or `eso-data-apps`. `secrets-apps` itself is trimmed to `external-secrets` +
`secrets-sync` and keeps its name (a member-list shrink, not worth forcing
ArgoCD to delete+recreate the whole parent Application for a cosmetic
rename). `wireguard-apps` also dropped the `module.wait_crds_healthy` it
used to carry "uniformly, whether or not it needed it" — it consumes no
CRD at all, so that dependency was pure dead time, the same anti-pattern
`standalone-apps` existing at all is meant to eliminate everywhere, not
just for OpenBao.

**The old combined `networking-apps` is split along the controller/resource
line**, generalizing infra#100's own proposal:
- `networking-controllers-apps` (`values-networking-controllers.yaml`):
  `envoy-gateway`, `cert-manager`, `cert-manager-webhook-scaleway` — these
  consume nothing but `crds-apps` being Established
  (`module.wait_crds_healthy`), no ExternalSecret.
- `networking-resources-apps` (`values-networking-resources.yaml`):
  `gateway-config`, `external-dns` — these have a real hard dependency on
  `networking-controllers-apps` being genuinely **Healthy**, not just the
  CRDs existing (`gateway-config`'s `ClusterIssuer`s are cert-manager.io
  -typed and fail outright at the API level if cert-manager's webhook
  isn't registered and serving yet). New
  `module.wait_networking_controllers_healthy` gate for exactly this. This
  domain also keeps the existing soft `depends_on = [eso_data_apps]` (for
  `cert-manager-webhook-secret`/`external-dns-secret`, same tolerance as
  before).
- `module.wait_networking_healthy` is renamed
  `module.wait_networking_resources_healthy` (watches
  `networking-resources-apps` — the tier every `*-gateway` HTTPRoute
  actually attaches its `Gateway` object to) and still gates
  `gateways-apps`.

**`gateways-apps` gained `openbao-gateway`** — moved out of the old
`networking-apps`, where it rode along as a bare HTTPRoute with "no reason
to pay for a whole domain for one HTTPRoute". Now that `gateways-apps`
already exists as the shared home for every product's `*-gateway` chart, it
was the one exception left behind rather than a real design choice — joining
it removes that inconsistency for free.

**Updated tier model** (superseded by "Consolidating wait-hops into
intra-Application waves" below — that section's table is the current
authoritative one; this is kept for the shape this build on):

| Tier | Gate | Apps |
|---|---|---|
| **0 — CRDs** | none | `crds-apps`: `gateway-api-crds`, `kube-prometheus-stack-crds`, `cert-manager-crds` |
| **0 — Standalone** | none | `standalone-apps`: `openbao`, `openbao-init` |
| **1 — Controllers, CRD-gated** | `module.wait_crds_healthy` | `monitoring-apps`, `networking-controllers-apps` |
| **1 — Controllers, self-managed CRDs** | `module.wait_standalone_healthy` (OpenBao readiness, not CRDs) | `secrets-apps` (`external-secrets` wave 0 → `secrets-sync` wave 1, ArgoCD's own intra-Application wave-gating orders the CRD-Established check before `secrets-sync`'s CRD-typed resources — see values-crds.yaml's own comment for why `external-secrets`/`velero` manage their own CRDs again as of 2026-08-27) |
| **1 — Restore, Velero-gated** | `module.wait_backups_healthy` | `restore-apps`: `cert-restore`, `grafana-restore` (own CRDs too — `backups-apps`'s `velero`) |
| **1 — Backups, self-managed CRDs** | none | `backups-apps`: `velero` |
| **2 — Uniform secrets data** | `module.wait_secrets_healthy` | `eso-data-apps` (unchanged — every `ExternalSecret` platform-wide, `secrets-sync`'s own `ClusterSecretStore`/`PushSecret` staying in Tier 1 as the one documented chicken-and-egg exception) |
| **1-soft** (secret-only, no CRD) | soft `depends_on = [eso_data_apps]` | `wireguard-apps`, `dex-apps`, `argocd-config-apps` |
| **1-soft + restore** | soft `eso_data_apps` + `module.wait_restore_healthy` | `grafana-apps` (own PVC restore) |
| **3 — CRD-resource, multi-gate** | `module.wait_networking_controllers_healthy` (hard) + soft `eso_data_apps` + `module.wait_restore_healthy` (own TLS-secret restore) | `networking-resources-apps`: `gateway-config`, `external-dns` |
| **4 — Gateway routes** | `module.wait_networking_resources_healthy` + soft `eso_data_apps` | `gateways-apps`: `dex-gateway`, `grafana-gateway`, `argocd-config-gateway`, `argo-workflows-gateway`, `openbao-gateway` |
| **2-chain** (unchanged) | `wait_dex_healthy` → `argo-workflows-apps`; `wait_argo_workflows_and_grafana_healthy` → `terraform-apply-apps` | unchanged |
| **Final** | `module.wait_all_domains_healthy` (membership updated to the full list above) → `helm_release.argocd_apps` (bootstrap) → `wait_bootstrap_healthy` | unchanged mechanism |

Net app-list change vs. infra#100's own proposal: same shape (new
`standalone-apps`, `networking-apps` split in two), `cert-manager-crds`
added to `crds-apps` (external-secrets/velero's own CRD sets were tried
there too, then reverted 2026-08-27 — see above), a new `restore-apps`
domain (cert-restore/grafana-restore, extracted from two ArgoCD PreSync
hooks), `openbao-gateway` moved into `gateways-apps`, and the
argo-workflows exception named instead of silently absent. No gitops-repo
chart changes were needed for the networking/standalone split (same as
infra#100 found) — the CRD generalization needed `cert-manager`'s own
`crds.enabled: false` value flip plus its CRDs-only chart, and the
restore-apps extraction needed two brand-new charts
(`services/platform/gateway/cert-restore`,
`services/platform/monitoring/grafana-restore`) plus trimming the two
consumer charts they were extracted from.

## Consolidating wait-hops into intra-Application waves (2026-08-27)

Each `module.wait-argocd-apps-healthy` Job is real, non-trivial
wall-clock waiting — one alone (`wait-crds-healthy` on a full CRD set)
measured ~8.5 min live. ArgoCD's *intra-Application* sync-wave ordering,
by contrast, is free and — unlike its cross-Application ordering, which
failed live twice in this repo's history — a native reliable guarantee
(proven again 2026-08-27 for `external-secrets` wave 0 → `secrets-sync`
wave 1). So wherever two top-level Applications were only ever ordered by
a Terraform Job, and the later one needs *only* what an earlier wave of a
single merged Application would already have made Healthy, they were
merged and the Job deleted. Three merges, each removing one Job:

- **`standalone-apps` + `secrets-apps` + `eso-data-apps` → one
  `secrets-apps`** (`values-secrets.yaml`): `openbao`/`openbao-init`/
  `external-secrets` wave 0 → `secrets-sync` wave 1 → every product
  `ExternalSecret` wave 2. Deletes `module.wait_standalone_healthy` and
  the `eso-data-apps`-after-`wait_secrets_healthy` hop; `module.wait_secrets_healthy`
  survives as the single gate and now transitively covers OpenBao
  readiness, ESO's CRDs Established, and ESO's webhook serving.
- **`backups-apps` + `restore-apps` → one `backups-apps`**
  (`values-backups.yaml`): `velero` wave 0 → `cert-restore`/
  `grafana-restore` wave 1. Deletes `module.wait_restore_healthy`;
  `module.wait_backups_healthy` survives and now covers the restore Jobs
  too.
- **`networking-resources-apps` + `gateways-apps` → one
  `networking-resources-apps`** (`values-networking-resources.yaml`):
  `gateway-config`/`external-dns` wave 0 → every `*-gateway` HTTPRoute
  wave 1. Deletes `module.wait_networking_resources_healthy`.

**Networking Controllers (`networking-controllers-apps`) deliberately
stays its own separately-gated Application** — NOT merged with
Resources+Gateways. Terraform can only gate an Application's *creation*,
not pause mid-sync between two of its own waves, so merging the
controllers in would force them to also wait for Secrets+Backups before
even starting, delaying them for no reason (today they start as soon as
`crds-apps` is Established, in parallel with everything else in Tier 0).

**One correctness upgrade, not just a simplification:**
`networking-resources-apps`' `gateway-config`/`external-dns` had only a
*soft* `depends_on = [eso_data_apps]` for `cert-manager-webhook-secret`/
`external-dns-secret`; it's now a hard `module.wait_secrets_healthy` gate,
since merge 1 made that the single check covering every ExternalSecret's
webhook-serving readiness.

**Current tier model** (authoritative — supersedes the table above):

| Tier | Gate | Apps |
|---|---|---|
| **0 — CRDs** | none | `crds-apps`: `gateway-api-crds`, `kube-prometheus-stack-crds`, `cert-manager-crds` |
| **0 — Secrets** | none (own waves 0→1→2) | `secrets-apps`: w0 `openbao`, `openbao-init`, `external-secrets` → w1 `secrets-sync` → w2 every `*-secret` `ExternalSecret` |
| **0 — Backups** | none (own waves 0→1) | `backups-apps`: w0 `velero` → w1 `cert-restore`, `grafana-restore` |
| **0 — Monitoring / Net-controllers** | `module.wait_crds_healthy` | `monitoring-apps`, `networking-controllers-apps` |
| **1 — Secret-only (soft)** | soft `depends_on = [secrets_apps]` | `wireguard-apps`, `dex-apps`, `argocd-config-apps` |
| **1 — Grafana** | soft `secrets_apps` + `module.wait_backups_healthy` (own PVC restore) | `grafana-apps` |
| **1 — Net-resources + gateways** | `module.wait_networking_controllers_healthy` + `module.wait_secrets_healthy` + `module.wait_backups_healthy` (all hard) | `networking-resources-apps`: w0 `gateway-config`, `external-dns` → w1 every `*-gateway` HTTPRoute (`dex`/`grafana`/`argocd-config`/`argo-workflows`/`openbao`) |
| **2-chain** (unchanged) | `wait_dex_healthy` → `argo-workflows-apps`; `wait_argo_workflows_and_grafana_healthy` → `terraform-apply-apps` | unchanged |
| **Final** | `module.wait_all_domains_healthy` (12 top-level apps now, was 15) → `helm_release.argocd_apps` (bootstrap) → `wait_bootstrap_healthy` | unchanged mechanism |

Wait-module count: **10 → 7** (`wait_crds_healthy`, `wait_secrets_healthy`,
`wait_backups_healthy`, `wait_networking_controllers_healthy`,
`wait_dex_healthy`, `wait_argo_workflows_and_grafana_healthy`,
`wait_all_domains_healthy`). No gitops-repo chart changes — only which
parent Application/wave claims each child moved. `bootstrap` chart
untouched.

## Teardown: use `hard-destroy`, not soft `tofu destroy`

Confirmed live 2026-08-28: a soft `tofu destroy` of this root
deadlocks. `main.tf`'s Terraform-managed namespaces (`cert-manager`,
`external-dns`, `monitoring`) get deleted early, but `cert-manager`'s
aggregated `APIService v1alpha1.acme.scaleway.com` (from
`cert-manager-webhook-scaleway`, owned by the `networking-controllers-apps`
Application) is only removed when that Application is torn down — which
Terraform does *last*. The orphaned `APIService` goes `ServiceNotFound`,
which wedges API discovery and the garbage collector cluster-wide, so no
namespace finalizes and every ArgoCD `resources-finalizer` cascade stalls
until a 30-min helm-uninstall timeout. Pre-existing, unrelated to any
wave-hop change. The `scaleway.yml` workflow's `hard-destroy` command
(state-`rm`s the helm/kubernetes resources, then destroys only the
Scaleway cluster) is the supported teardown for this disposable homelab
root. A proper soft-destroy fix would be a `null_resource { when =
destroy }` that strips that `APIService` before the namespaces go, mirror
of `main.tf`'s `null_resource.velero_namespace_predelete_cleanup`.
