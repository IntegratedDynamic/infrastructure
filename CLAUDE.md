# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Setup

```bash
mise install          # Install all tools (kubectl, minikube, terraform, helm, argocd, actionlint)
.githooks/install.sh  # Configure git to use local hooks directory
```

**Before running `terraform init`/`plan`/`apply` locally against any
Scaleway-hosted root** (every root except `00-foundation/aws` — see
`00-foundation/scaleway/README.md`'s "Cross-root reads need no manual
credential setup" section for the full explanation):

```bash
export AWS_ACCESS_KEY_ID=$(scw config get access-key)
export AWS_SECRET_ACCESS_KEY=$(scw config get secret-key)
```

Terraform's native `backend "s3" {}` block can only read the literal
`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` env var names for any
S3-compatible endpoint, Scaleway included — it never reads `scw` CLI config,
so `scw config info` showing valid credentials does not mean the backend has
them. Skipping this fails with an opaque `403 Forbidden` on `ListObjectsV2`
that looks identical whether credentials are missing, wrong, or real
(non-Scaleway) AWS credentials are ambient instead.

## Commands

```bash
# Local cluster (minikube)
mise run dev             # Full local env: start minikube + terraform init + apply
mise run reset           # Destroy minikube cluster

# Provider lock files
mise run lock            # Re-generate every root's .terraform.lock.hcl for darwin_arm64 + linux_amd64

# Linting
actionlint .github/workflows/*.yml   # Lint GitHub Actions workflows (also runs as pre-push hook)
```

### Re-running `providers lock`

The `.terraform.lock.hcl` in each root must cover **both** `darwin_arm64` (local dev) and `linux_amd64` (CI). Re-run `mise run lock` whenever you:

- bump a provider version constraint in any `version.tf`
- add a new provider to a root
- see a CI failure on the `Verify Terraform Lock Files` workflow

`mise run lock` is equivalent to:

```bash
terraform -chdir=00-foundation/aws                providers lock -platform=darwin_arm64 -platform=linux_amd64
terraform -chdir=00-foundation/scaleway             providers lock -platform=darwin_arm64 -platform=linux_amd64
terraform -chdir=01-iam/bootstrap/aws               providers lock -platform=darwin_arm64 -platform=linux_amd64
terraform -chdir=01-iam/bootstrap/scaleway          providers lock -platform=darwin_arm64 -platform=linux_amd64
terraform -chdir=01-iam/workload/scaleway           providers lock -platform=darwin_arm64 -platform=linux_amd64
terraform -chdir=02-encryption/aws                  providers lock -platform=darwin_arm64 -platform=linux_amd64
terraform -chdir=03-storage/scaleway                providers lock -platform=darwin_arm64 -platform=linux_amd64
terraform -chdir=04-vpn/wireguard-site-to-site      providers lock -platform=darwin_arm64 -platform=linux_amd64
terraform -chdir=04-vpn/wireguard-exit              providers lock -platform=darwin_arm64 -platform=linux_amd64
terraform -chdir=10-cluster/local                   providers lock -platform=darwin_arm64 -platform=linux_amd64
terraform -chdir=10-cluster/scaleway                providers lock -platform=darwin_arm64 -platform=linux_amd64
terraform -chdir=11-secrets/openbao/bootstrap        providers lock -platform=darwin_arm64 -platform=linux_amd64
terraform -chdir=12-monitoring/grafana/bootstrap     providers lock -platform=darwin_arm64 -platform=linux_amd64
terraform -chdir=12-monitoring/grafana/managed       providers lock -platform=darwin_arm64 -platform=linux_amd64
```

Commit the updated lock files alongside the version change.

## Architecture

Terraform roots are organized by **domain** — the top-level folder is a numeric
**pseudo-ID**, generally named after the domain's function rather than what it
literally owns (`00-foundation`, `01-iam`, `02-encryption`...). The number
roughly encodes apply order / blast-radius
across domains, though it's a convention, not something any tooling enforces.
Gaps in the sequence (`05`-`09`) are deliberate — room for future domains
without a renumbering cascade; `10-cluster` in particular was moved up from
`02-` on purpose to free up low numbers for domains like `02-encryption`.
`11-secrets` and `12-monitoring` (2026-08-24, moved from `05-secrets` and
`06-monitoring`) deliberately sit **after** `10-cluster`: both only apply
successfully once the cluster exists and gitops has deployed the tool
they configure onto it (`05-secrets/openbao/bootstrap`'s vault provider talks
to OpenBao's own live route, `06-monitoring/grafana/bootstrap`'s grafana
provider talks to Grafana's) — numbering them ahead of `10-cluster` inverted
the apply-order convention the prefix is supposed to encode. `06` had briefly
been the first `07`-`09` gap filled (`06-monitoring/`); that gap is open again
now that monitoring moved to `12`.

The second path segment is the **cloud provider** a root targets (`aws`,
`scaleway`) — a domain with only one provider still nests under it (e.g.
`00-foundation/aws/`), so a second provider can be added later without a
restructure. Within `01-iam/`, there's a further split by **lifecycle / who
applies**: `bootstrap/` = human/admin-applied trust anchors (rare changes, need
admin creds), `workload/` = admin-applied identities that aren't trust anchors
(scoped credentials for a specific in-cluster workload, e.g. external-dns).

```
modules/
  scaleway-machine-identity/   # shared: IAM application + map of policies +
                               #   rotating API key. Used by every Scaleway
                               #   identity below instead of copy-pasted HCL.
  scaleway-bucket-with-identity/ # shared: one bucket + (by default,
                               #   create_identity = true) one scoped
                               #   identity, generated/unique-by-construction
                               #   from bucket_name (wraps
                               #   scaleway-machine-identity). Used by
                               #   03-storage/scaleway's and
                               #   00-foundation/scaleway's for_each over
                               #   var.buckets/var.state_buckets — add a
                               #   bucket there by adding a map entry, not
                               #   new resources. expiration_enabled = false
                               #   opts a bucket's current-version object out
                               #   of ever expiring (state buckets).
00-foundation/
  aws/                         # domain: the base AWS layer everything else
                               #   used to depend on — the S3 bucket that USED
                               #   TO hold every root's remote state (now only
                               #   its own — see scaleway/ below), PLUS the
                               #   GitHub OIDC provider + the one role
                               #   (terraform-state-access) every workflow in
                               #   this repo assumes for state R/W.
                               #   Admin-applied.
  scaleway/                    # domain: where every other root's state now
                               #   lives (migrated 2026-08-19) — one dedicated
                               #   bucket PER CONSUMING ROOT (var.state_buckets),
                               #   not one shared bucket, since Scaleway IAM
                               #   can only scope Object Storage permissions
                               #   at the project level. See its README for
                               #   the confirmed backend config (S3 native
                               #   locking works, path-style + skip_s3_checksum
                               #   required) and the still-open follow-up
                               #   (.github/actions/terraform/action.yml isn't
                               #   updated for Scaleway-hosted backends yet).
01-iam/                        # domain: IAM identities & grants (non-AWS)
  bootstrap/
    aws/                       #   CI role scoped to 02-encryption/aws only
                               #     (KMS + IAM user/access-key CRUD, plus the
                               #     same state-bucket policy terraform-state-
                               #     access uses) — see that section below
    scaleway/                  #   Scaleway CI identity (github-ci: IAM app +
                               #     2 policies + static API key)
  workload/
    scaleway/                  #   simple scoped workload identities, one
                               #     module block per var.identities entry:
                               #     external-dns (DNS zone record R/W only —
                               #     no bucket, no DNS zone resource managed
                               #     here) and argo-workflows-state (Object
                               #     Storage R/W for the terraform-apply
                               #     CronWorkflows' own state reads)
02-encryption/
  aws/                         # domain: AWS KMS key + dedicated IAM user for
                               #   OpenBao's auto-unseal. Standalone rather than
                               #   folded into 11-secrets/openbao (different
                               #   provider, different pattern — an AWS key/user
                               #   pair, not an OpenBao/Vault-provider resource)
03-storage/
  scaleway/                    # domain: Scaleway tool buckets + their scoped
                               #   identities — backup, velero, thanos, loki,
                               #   tempo, argo_workflows_logs today; home for
                               #   future tool buckets
04-vpn/
  wireguard-site-to-site/      # domain: WireGuard peer keypairs for the
                               #   OpenBao tunnel (11-secrets/openbao's vault
                               #   provider, not the human OIDC/UI login) —
                               #   EXPLICITLY TEMPORARY, see its own README
                               #   for why it isn't 01-iam/ or 11-secrets/ yet.
                               #   Renamed from wireguard/ once a second,
                               #   unrelated WireGuard deployment showed up
                               #   below — pure directory rename, zero state
                               #   migration (workspace_key_prefix/tfvars
                               #   filename untouched, see "Backend keys are
                               #   decoupled from paths" below)
  wireguard-exit/              # domain: a second, unrelated WireGuard
                               #   deployment — a consumer-style "exit node".
                               #   Peers route ALL their traffic through it
                               #   (real kernel IP forwarding + NAT), unlike
                               #   the site-to-site tunnel's app-layer
                               #   proxying — different scope, different
                               #   threat model, deliberately not an
                               #   extension of wireguard-site-to-site/. Own
                               #   keys, own gitops app, own README
10-cluster/                    # domain: the Kubernetes platform (moved up from
                               #   02- to free up low numbers for future domains)
  local/                       #   minikube — local dev and debugging. Local backend (local files)
  scaleway/                    #   Scaleway Kapsule cluster + ArgoCD bootstrap (homelab; WIP)
11-secrets/                    # (was 05-secrets/, moved 2026-08-24 to sit
                               #   after 10-cluster — see the numbering note
                               #   above)
  openbao/                     # domain: OpenBao itself (bootstrap/ + managed/,
                               #   see that directory) — untouched by the
                               #   2026-07-30 buckets/IAM consolidation
12-monitoring/                 # (was 06-monitoring/, moved 2026-08-24, same
                               #   reason as 11-secrets/ above)
  grafana/                     # domain: Grafana, managed by Terraform
                               #   (bootstrap/ + managed/, same split as
                               #   11-secrets/openbao) — its own domain
                               #   since 11-secrets/ is scoped to OpenBao's
                               #   own config specifically, not any tool
                               #   that happens to need IaC.
```

**The dependency spine** runs forward: `00-foundation/aws` (bucket + CI's AWS
role) → everything else, since every other root's backend USED TO point at
that bucket. As of the AWS→Scaleway state-backend migration
(`00-foundation/scaleway`, 2026-08-19), only `00-foundation/aws` itself still
does — every other root's state now lives in its own dedicated bucket under
`00-foundation/scaleway` instead (one bucket per root, see that root's
README for why). `terraform-state-access` (the role every workflow assumes
by default) is scoped to exactly S3 read/write on the AWS state bucket — no
IAM-management capability at all — but is now only load-bearing for roots
that still live there (`00-foundation/aws` itself); its continued presence
in `.github/actions/terraform/action.yml` as a required input is dead weight
for every migrated root's workflow until that action is updated to pass
Scaleway credentials instead (follow-up work, not yet done). Only one other
role exists, `01-iam/bootstrap/aws`'s `openbao-unseal-ci`, and it's narrowly
scoped too: KMS + IAM user/access-key CRUD under `/openbao/`, nothing
broader, plus (via a `terraform_remote_state` lookup, not a hardcoded ARN)
the same state-bucket policy `terraform-state-access` uses — a grant that's
now vestigial too, since `01-iam/bootstrap/aws`'s own backend also migrated
to Scaleway and no longer needs it. (This two-role setup replaced a larger system, retired 2026-07-30: the
original `01-iam/bootstrap/aws` + `01-iam/ci-managed/aws-state-access` together
built a "CI can safely mint further IAM roles" mechanism — a permissions
boundary + a policy letting the CI role create/attach *any* other role under a
managed path — whose only actual consumer was minting the one role that did
state R/W. Once that role's job narrowed to exactly "read/write this bucket,"
there was no general IAM-management capability left to guard against
escalating, so the guardrail system went with it. `02-encryption/aws` needing
its own broader-than-S3 AWS rights later is why `01-iam/bootstrap/aws` came
back — but scoped to just that one domain's resource types, not "create any
role.")

**Backend keys are decoupled from paths, but by convention they're kept in
sync.** Each root pins its own `workspace_key_prefix` in `version.tf`, and the
workspace name comes from the `env/<name>.tfvars` filename — **neither is
mechanically tied to the directory**, so a `git mv` alone never breaks a
backend. As of the 2026-08-24 workspace-naming refacto, every root's prefix
mirrors its own directory path, and every workspace name is that path
flattened with hyphens and suffixed `-dev` (the environment this whole repo
runs — a personal dev homelab, never staging or prod), e.g.
`11-secrets/openbao/bootstrap` → prefix `11-secrets/openbao/bootstrap`,
workspace `11-secrets-openbao-bootstrap-dev`. Before this refacto several
roots had drifted out of sync after being moved or renamed (prefixes in the
wrong segment order, workspace names inherited from a since-renamed
directory, `10-cluster/scaleway` even carrying the misleading name
`02-cluster-staging`) — all fixed by migrating each root's state into its new
prefix/workspace via `terraform state pull` + `state push` (old state objects
left orphaned in the same bucket, never deleted — see each root's
`version.tf` header comment for its specific before/after).

**If a root's workspace name feeds a real resource name** (grep
`terraform.workspace` in `main.tf` — as of this refacto that's
`02-encryption/aws` (AWS KMS alias + IAM user; **`aws_iam_access_key.user` is
`ForceNew`**, so a workspace rename there would rotate OpenBao's unseal
credential unless the derived name is first frozen to a hardcoded local, as
`02-encryption/aws/main.tf`'s `local.unseal_name` now is), `03-storage/scaleway`,
and `01-iam/workload/scaleway` (both Scaleway IAM application/policy names —
confirmed in-place-renamable, no credential rotation, since Scaleway API keys
are tied to `application_id` not name) — always verify with `terraform plan`
before applying a workspace rename, and don't assume every provider handles
a name change the same way AWS's IAM access key does.

Going forward: if you move a root to a new directory, keep the prefix/
workspace in sync **only if you also migrate the state the same way**
(pull from the old location, reconfigure, push into the new one, leave the
old object orphaned). A pure `git mv` with the prefix/tfvars left alone is
still valid and zero-risk — just don't let the drift linger indefinitely
the way it did before this refacto.

### `10-cluster/*`

Terraform here is only a **one-time bootstrapper** — everything after ArgoCD is up lives in the `gitops` repo. The cluster internal state nor status will be reflected in the terraform state. 

### `10-cluster/local/`

Warning : This environment expect you an accessible local kubernetes cluster access, likely configured within your ~/.kube/config. This is automatically handled via `mise run dev`

Two-step, one-time bootstrap:
1. Fetch secrets from **Infisical** (universal auth machine identity). Credentials come from `nico.auto.tfvars` (per-developer, not shared).
2. Deploy **ArgoCD** via Helm with the admin bcrypt password hash from Infisical (pre-hashed to prevent Terraform drift).
3. Deploy the **argocd-apps bootstrap** Application, pointing ArgoCD at `https://github.com/IntegratedDynamic/gitops.git`. ArgoCD then self-manages all further cluster state from that separate GitOps repo.

### `10-cluster/scaleway/`

Same bootstrap pattern as `local/`, but with the Kapsule cluster + node pool (`DEV1-M`, min=0/max=3) instead.

**Secrets/monitoring/backups/networking (infra#84, 2026-08-24 + scope
addition 2026-08-25):** OpenBao+ESO, monitoring
(kube-prometheus-stack/loki/tempo/alloy/otel-collector, NOT Grafana — that
stays in `gitops`), Velero, and cluster networking (envoy-gateway,
cert-manager + its Scaleway DNS01 webhook, external-dns, gateway-config —
NOT the per-product `*-gateway` HTTPRoute charts like `dex-gateway`, which
stay in `gitops`) were extracted from `gitops` repo's `bootstrap`
app-of-apps into this root's own `platform-apps/` chart — four ArgoCD
Applications (`secrets-apps`/`monitoring-apps`/`backups-apps`/`networking-apps`,
created via `argocd.tf`'s `argocd_platform_apps` helm_release, same
`argocd-apps` chart mechanism `bootstrap` itself uses) that start in
parallel with each other and must reach Healthy before `bootstrap`'s own
Application resource is even created — a real Terraform `depends_on`
(`null_resource.wait_platform_apps_healthy`, polling via `kubectl` +
a self-generated kubeconfig), not an ArgoCD sync-wave, since ArgoCD has no
native ordering primitive across independent top-level Applications (only
within one parent's own sync — see `platform-apps/README.md`). The actual
product charts (`services/platform/openbao/chart`, `monitoring/chart`, ...)
are untouched, still pulled from the `gitops` repo — only which parent
Application claims them as managed resources moved. Four credentials
Terraform already originates (thanos/loki/tempo/velero Object Storage
access keys, from `03-storage/scaleway`) are now written directly as
`kubernetes_secret` resources in this root's `main.tf` instead of via
OpenBao+ESO's `ExternalSecret` round-trip — OpenBao (`11-secrets/openbao/managed`)
still gets the same values written to it independently, staying the
audited source of truth, but ESO is no longer in the delivery path for
these four. `networking-apps`' own two secrets
(`cert-manager-webhook-secret`/`external-dns-secret`, the Scaleway
Domains/DNS API credential) deliberately keep the OpenBao+ESO
`ExternalSecret` path unchanged instead — Terraform doesn't originate that
credential the way it does the four Object Storage ones, so there's nothing
to gain by bypassing ESO there (self-heals against `secrets-apps` the same
way every other `*-secret` chart in `gitops`'s `bootstrap` already
tolerates). `gateway-config`'s own dependency on Velero (its cert-restore
PreSync hook) is left ungated for the same "already self-contained,
fails open" reason documented in `platform-apps/README.md` — no
Terraform-level wait between `networking-apps` and `backups-apps`.
`monitoring`/`velero` namespaces are Terraform-managed
(`kubernetes_namespace`, same pattern `openbao`'s namespace already used)
purely because these Secrets must exist before ArgoCD's own
`CreateNamespace=true` would otherwise create them — every other extracted
app's namespace is still ArgoCD-created, unaffected. See
`platform-apps/README.md` for the full design rationale (including the
namespace and secret-delivery decisions), and `gitops` repo's
`bootstrap/README.md` for what changed on that side.

### `00-foundation/aws/`

The shared org S3 bucket holding **every** root's remote state (built on `terraform-aws-modules/s3-bucket`: versioning, SSE, public-access block, TLS-only). Chicken-and-egg: its own state lives in the bucket it creates (one-time local-state bootstrap — see its README). Also creates the GitHub OIDC provider and the one role, `terraform-state-access` (via `terraform-aws-modules/iam`), every GitHub Actions workflow in this repo assumes — trust scoped to `repo:IntegratedDynamic/infrastructure:*`, policy scoped to exactly S3 list/get/put/delete on the state bucket, nothing else. Wired to CI via `vars.AWS_TERRAFORM_ROLE_ARN`. Applied by an admin (this root creates the very identity CI would otherwise need to apply it). See its README.

### `00-foundation/scaleway/`

Scaleway counterpart to `00-foundation/aws/` — and, as of 2026-08-19, where
every root's state actually lives except `00-foundation/aws` itself. Unlike
the AWS bucket (one bucket, many `workspace_key_prefix` values), this is
**one dedicated Object Storage bucket per consuming root module**
(`var.state_buckets`, a `for_each` map — add a future root's bucket by
adding a map entry, no new resources) — Scaleway IAM can only scope Object
Storage permissions at the project level, so a shared bucket would give every
root's CI identity read/write on every other root's state with no way to
narrow it, worse than the AWS setup's already-documented lack of per-root
isolation. Built on `modules/scaleway-bucket-with-identity` (the same module
`03-storage/scaleway` uses) — as of 2026-08-19, each bucket gets its **own**
dedicated identity by default (`create_identity = true`, generated/
unique-by-construction names from `bucket_name`), not one shared identity
for all buckets; a root needing broader Scaleway rights sets
`create_identity = false` and gets its identity in `01-iam/` instead. This
root's own state is self-hosted here too
(`state_buckets["foundation_scaleway"]`) — bootstrapped the same one-time
chicken-and-egg way `00-foundation/aws` was: created while its state still
lived in the AWS bucket, then repointed and migrated.

The migration procedure was rehearsed first against a throwaway root
(`99-scratch/migration-test`, since deleted) — confirmed working — then
rolled out to every real domain (`01-iam/*`, `02-encryption/aws`,
`03-storage/scaleway`, `04-vpn/*`, `11-secrets/openbao/*`,
`12-monitoring/grafana/*`, `10-cluster/scaleway`) plus this root itself. See
this root's README for the confirmed findings: `use_lockfile` native S3
locking works against Scaleway, and the required backend config is
`use_path_style = true` + `skip_s3_checksum = true` + a literal
`endpoints.s3` — a Terraform hard constraint (`backend` blocks can't
reference variables) that's why those five lines are repeated verbatim in
every migrated root's `version.tf` rather than parametrized.

Every `data "terraform_remote_state"` cross-root read repo-wide (there are
~11 of them — see `11-secrets/openbao/managed/main.tf` for the densest
cluster, 4 in one file) was updated to point at the new buckets too, and
**parametrized**: bucket/key are now named variables set in that root's
`env/*.tfvars` (visible as config), not hardcoded literals in `.tf`. The
`data` source's own technical Scaleway-endpoint attributes (region,
`skip_*`, `endpoints`) — unlike a `backend` block — CAN reference locals, so
each file with cross-root reads defines one `local.scaleway_state_backend`
merged into every `config` block instead of repeating those five lines per
data source.

**Known follow-up, not yet done**: `.github/actions/terraform/action.yml`
still only knows how to assume an AWS role for backend state R/W — every
migrated root's workflow needs it updated to pass Scaleway credentials via
`-backend-config` instead (needed *specifically* for roots that also carry a
real `provider "aws"` block, e.g. `02-encryption/aws`, since Terraform's s3
backend and that provider both read `AWS_ACCESS_KEY_ID`/
`AWS_SECRET_ACCESS_KEY` — colliding if both need real values at once).
Locally this was worked around per-command with an explicit
`-backend-config=<gitignored file>` instead of ambient env vars. The
rehearsal bucket (`state_buckets["scratch"]`) is intentionally left in
place, `prevent_destroy` included — cleanup is a manual admin action on
their own timeline, not something to automate away.

### `01-iam/bootstrap/aws/`

CI role (`openbao-unseal-ci`) scoped to exactly what `02-encryption/aws` needs: full CRUD (create/read/update/**destroy**) on a KMS key + alias (necessarily unscoped by resource — KMS key IDs are random, `kms:CreateKey` has no resource-level permission support) and on an IAM user + access key scoped to the `/openbao/` path (matching that root's `aws_iam_user` path). Also attaches the same state-bucket policy `terraform-state-access` uses — read via a `data.terraform_remote_state` lookup at `00-foundation/aws`, not hardcoded — so this role can read/write the bucket for its own backend too. OIDC-trusted, scoped to `repo:IntegratedDynamic/infrastructure:*`. No general IAM-management capability (can't create roles, can't touch anything outside `/openbao/`), unlike the original `01-iam/bootstrap/aws` this replaces the *name* of but not the *design* of.

### `01-iam/bootstrap/scaleway/`

Standalone root that stands up the **Scaleway IAM identity GitHub Actions uses to authenticate to Scaleway**: a dedicated IAM application + two policies (`Kubernetes`/`VPC`/`PrivateNetworks` FullAccess + `IPAMReadOnly` for cluster management; Object Storage + IAM application/policy management for the storage domain's CI workflow) + an API key, via `modules/scaleway-machine-identity`. GitHub secrets (`SCW_ACCESS_KEY` / `SCW_SECRET_KEY`) are set manually via `gh secret set` (Infisical, which used to carry this, is retired). Keyless GitHub-OIDC → Scaleway is a non-goal — blocked upstream (Scaleway IAM is not an OIDC relying party). See `01-iam/bootstrap/scaleway/README.md`.

### `01-iam/workload/scaleway/`

One `module "identities" { for_each = var.identities }` block (via `modules/scaleway-machine-identity`, single policy per identity — this domain is for simple scoped workload credentials, not CI trust anchors) — two identities today: `external-dns` (Scaleway `DomainsDNSFullAccess`, scoped to the project scalepack.fr's zone lives in; no DNS zone/record resource is Terraform-managed here) and `argo-workflows-state` (Object Storage R/W, project-scoped, for the terraform-apply CronWorkflows' own cross-root state reads — its key leaves the admin's machine and lands on the cluster itself, unlike every other identity in this repo). Add a future workload identity by adding a map entry to `var.identities`, no new `.tf` resources. `workload_access_key`/`workload_secret_key` outputs stay pinned to `external-dns` specifically (11-secrets/openbao/managed's `terraform_remote_state` reads them) — new identities' keys come from the generic `access_keys`/`secret_keys` map outputs instead. Moved here from `04-dns/scaleway` since it owns no bucket and isn't a CI trust anchor.

### `02-encryption/aws/`

AWS KMS key + a single-purpose IAM user for OpenBao's `seal "awskms"` auto-unseal (OpenBao runs on Scaleway Kapsule, not AWS, so there's no instance profile to lean on — a static AWS access key is required). Standalone domain rather than folded into `11-secrets/openbao/` (different provider/pattern — plain AWS resources, not an OpenBao/Vault-provider resource) or left in `03-storage/scaleway` (not a bucket, not really "storage"). Managed via the `01-iam/bootstrap/aws` role above — see the root's `main.tf` header comment for the full apply-path rationale. Moved here from `06-openbao-unseal/aws` to free up a low domain number. `local.unseal_name` is hardcoded rather than derived from `terraform.workspace` — see "Backend keys are decoupled from paths" above for why.

### `03-storage/scaleway/`

Scaleway tool buckets + their scoped identities, each with its own bucket AND its own workload identity — kept as separate buckets/identities (not a shared bucket) because Velero writing into a shared bucket once broke OpenBao's `s3cmd`-based retention cleanup (confirmed live 2026-07-28), and Scaleway IAM can't scope Object Storage permissions below project level anyway. Six today: `backup` (OpenBao's own raft snapshots), `velero` (Kubernetes backups), `thanos` (Prometheus TSDB block storage, near-term/no-GLACIER), `loki` (log chunk storage, 1-day rolling retention matching Loki's own compactor), `tempo` (trace block storage, same 1-day shape), `argo_workflows_logs` (archived Argo Workflows container logs, same 1-day shape). One `module "buckets"` block with `for_each = var.buckets` (via `modules/scaleway-bucket-with-identity`) instantiates every bucket in `main.tf` — add a future tool bucket by adding a map entry to `var.buckets`, no new `.tf` resources. Renamed from `03-backup/scaleway` (which also held the OpenBao unseal KMS resources, now `02-encryption/aws`).

## Conventions

**Branches**: `<type>/<description>` — lowercase, hyphens only. Types: `feature/`, `bugfix/`, `hotfix/`, `ci/`, `chore/`.

**Commits**: Conventional Commits — `<type>[scope]: <description>`. Types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `chore`, `ci`.

**PRs**: After each commit + push on a branch, create a draft PR if none exists. Title: `<type>: description`. Body: context, changes, linked issues (`Closes #123`), test instructions. Use [Conventional Comments](https://conventionalcomments.org/) in reviews (`praise`, `nitpick`, `suggestion`, `issue`, `todo`, `question`, `thought`).

**Terraform workspaces**: a root that runs through CI declares its workspace variables in an `env/` folder — one `env/<name>.tfvars` per workspace. The **filename (without `.tfvars`) is the terraform workspace name** (so state lands at `<workspace_key_prefix>/<name>/<key>`, isolated per root) and the **file contents are that workspace's variable values**. Name it `<root-path-flattened-with-hyphens>-<env>` (e.g. `11-secrets-openbao-bootstrap-dev`) — see "Backend keys are decoupled from paths" above for the full convention and why a rename needs a real state migration, not just a file rename. The reusable **composite action `.github/actions/terraform`** takes `root` + `tfvars-file` + `command` (`plan`/`apply`/`destroy`) + `aws-role-arn` (all non-secret inputs) and runs `workspace select <name>` + the command `-var-file=env/<name>.tfvars`, after minting an Infisical OIDC token (skippable) and assuming the AWS role via OIDC. The action takes **no secret inputs**: provider credentials (`SCW_*`, `INFISICAL_MACHINE_IDENTITY_ID`) are read from the job env. The calling **workflow** owns the trigger→command mapping (push → apply, schedule → destroy, else plan), the `concurrency` guard, and the `environment` that scopes credentials — Scaleway keys live in the `scaleway` environment and are exposed to the action as job `env:` (never as plain inputs). The repo must be checked out before calling the action (it is a local action). This replaces the old reliance on a local, gitignored `.terraform/environment` (invisible to CI — a `default`-workspace run collides on the state key).

<!-- SPECKIT START -->
For additional context about technologies to be used, project structure,
shell commands, and other important information, read the current plan:
`specs/001-backup-s3-foundation/plan.md`
<!-- SPECKIT END -->

## Roadmap conventions

Vocabulaire de specs/roadmap (EARS, `Done quand:`/`Dépend de:`, phases Spec Kit) :
@../orchestration/CONVENTIONS.md

> Fallback : si ce repo est cloné seul (le `@import` ci-dessus ne résout pas),
> le fichier vit dans le repo d'orchestration `orchestration/CONVENTIONS.md`
> (source de vérité de la roadmap cross-repo).
