# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Setup

```bash
mise install          # Install all tools (kubectl, minikube, terraform, helm, argocd, actionlint)
.githooks/install.sh  # Configure git to use local hooks directory
```

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
terraform -chdir=01-iam/bootstrap/aws               providers lock -platform=darwin_arm64 -platform=linux_amd64
terraform -chdir=01-iam/bootstrap/scaleway          providers lock -platform=darwin_arm64 -platform=linux_amd64
terraform -chdir=01-iam/workload/scaleway           providers lock -platform=darwin_arm64 -platform=linux_amd64
terraform -chdir=02-encryption/aws                  providers lock -platform=darwin_arm64 -platform=linux_amd64
terraform -chdir=03-storage/scaleway                providers lock -platform=darwin_arm64 -platform=linux_amd64
terraform -chdir=04-vpn/wireguard-site-to-site      providers lock -platform=darwin_arm64 -platform=linux_amd64
terraform -chdir=04-vpn/wireguard-exit              providers lock -platform=darwin_arm64 -platform=linux_amd64
terraform -chdir=05-secrets/openbao/bootstrap        providers lock -platform=darwin_arm64 -platform=linux_amd64
terraform -chdir=06-monitoring/grafana/bootstrap     providers lock -platform=darwin_arm64 -platform=linux_amd64
terraform -chdir=06-monitoring/grafana/managed       providers lock -platform=darwin_arm64 -platform=linux_amd64
terraform -chdir=10-cluster/local                   providers lock -platform=darwin_arm64 -platform=linux_amd64
terraform -chdir=10-cluster/scaleway                providers lock -platform=darwin_arm64 -platform=linux_amd64
```

Commit the updated lock files alongside the version change.

## Architecture

Terraform roots are organized by **domain** — the top-level folder is a numeric
**pseudo-ID**, generally named after the domain's function rather than what it
literally owns (`00-foundation`, `01-iam`, `02-encryption`...). The number
roughly encodes apply order / blast-radius
across domains, though it's a convention, not something any tooling enforces.
Gaps in the sequence (`04`, `07`-`09`) are deliberate — room for future domains
without a renumbering cascade; `10-cluster` in particular was moved up from
`02-` on purpose to free up low numbers for domains like `02-encryption`. `06`
was the first gap filled: `06-monitoring/` (Terraform-managed config for the
monitoring stack's own tools — the tools themselves are gitops-deployed).

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
  scaleway-bucket-with-identity/ # shared: one bucket + one scoped identity
                               #   (wraps scaleway-machine-identity). Used by
                               #   03-storage/scaleway's for_each over
                               #   var.buckets — add a tool bucket there by
                               #   adding a map entry, not new resources.
00-foundation/
  aws/                         # domain: the base AWS layer everything else
                               #   depends on — the S3 bucket holding every
                               #   root's remote state, PLUS the GitHub OIDC
                               #   provider + the one role (terraform-state-
                               #   access) every workflow in this repo assumes
                               #   for state R/W. Admin-applied.
01-iam/                        # domain: IAM identities & grants (non-AWS)
  bootstrap/
    aws/                       #   CI role scoped to 02-encryption/aws only
                               #     (KMS + IAM user/access-key CRUD, plus the
                               #     same state-bucket policy terraform-state-
                               #     access uses) — see that section below
    scaleway/                  #   Scaleway CI identity (github-ci: IAM app +
                               #     2 policies + static API key)
  workload/
    scaleway/                  #   external-dns workload identity (DNS zone
                               #     record R/W only — no bucket, no DNS zone
                               #     resource managed here)
02-encryption/
  aws/                         # domain: AWS KMS key + dedicated IAM user for
                               #   OpenBao's auto-unseal. Standalone rather than
                               #   folded into 05-secrets/openbao (different
                               #   provider, different pattern — an AWS key/user
                               #   pair, not an OpenBao/Vault-provider resource)
03-storage/
  scaleway/                    # domain: Scaleway tool buckets + their scoped
                               #   identities (backup, velero today; home for
                               #   future tool buckets)
04-vpn/
  wireguard-site-to-site/      # domain: WireGuard peer keypairs for the
                               #   OpenBao tunnel (05-secrets/openbao's vault
                               #   provider, not the human OIDC/UI login) —
                               #   EXPLICITLY TEMPORARY, see its own README
                               #   for why it isn't 01-iam/ or 05-secrets/ yet.
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
05-secrets/
  openbao/                     # domain: OpenBao itself (bootstrap/ + managed/,
                               #   see that directory) — untouched by the
                               #   2026-07-30 buckets/IAM consolidation
06-monitoring/
  grafana/                     # domain: Grafana, managed by Terraform
                               #   (bootstrap/ + managed/, same split as
                               #   05-secrets/openbao) — its own domain
                               #   since 05-secrets/ is scoped to OpenBao's
                               #   own config specifically, not any tool
                               #   that happens to need IaC. First of the
                               #   06-09 gaps to get filled.
10-cluster/                    # domain: the Kubernetes platform (moved up from
                               #   02- to free up low numbers for future domains)
  local/                       #   minikube — local dev and debugging. Local backend (local files)
  scaleway/                    #   Scaleway Kapsule cluster + ArgoCD bootstrap (homelab; WIP)
```

**The dependency spine** runs forward: `00-foundation/aws` (bucket + CI's AWS
role) → everything else, since every other root's backend points at that
bucket. `terraform-state-access` (the role every workflow assumes by default)
is scoped to exactly S3 read/write on the state bucket — no IAM-management
capability at all. Only one other role exists, `01-iam/bootstrap/aws`'s
`openbao-unseal-ci`, and it's narrowly scoped too: KMS + IAM user/access-key
CRUD under `/openbao/`, nothing broader, plus (via a `terraform_remote_state`
lookup, not a hardcoded ARN) the same state-bucket policy
`terraform-state-access` uses, so it can read/write the bucket for its own
backend. (This two-role setup replaced a larger system, retired 2026-07-30: the
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

**Backend keys are decoupled from paths.** Each root pins its own
`workspace_key_prefix` in `version.tf`, and the workspace name comes from the
`env/<name>.tfvars` filename — **neither is tied to the directory**. This means
moving a root to a new directory is a pure `git mv` with **zero state
migration**, as long as you don't also rename the tfvars file or touch
`workspace_key_prefix`. Several roots have been moved this way and deliberately
keep a prefix/workspace name that no longer matches their path (e.g.
`01-iam/bootstrap/scaleway` still uses prefix `github-ci`; `02-encryption/aws`
still uses the workspace name `03-backup-dev-bucket`, inherited from before its
resources were extracted from `03-storage/scaleway` — required there, since
`local.unseal_name` in that root derives the live KMS alias + IAM user name from
`terraform.workspace`, so renaming the workspace would rename/recreate them).
Don't "fix" a prefix or rename a tfvars file to match its new path unless you
also migrate the state.

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

### `00-foundation/aws/`

The shared org S3 bucket holding **every** root's remote state (built on `terraform-aws-modules/s3-bucket`: versioning, SSE, public-access block, TLS-only). Chicken-and-egg: its own state lives in the bucket it creates (one-time local-state bootstrap — see its README). Also creates the GitHub OIDC provider and the one role, `terraform-state-access` (via `terraform-aws-modules/iam`), every GitHub Actions workflow in this repo assumes — trust scoped to `repo:IntegratedDynamic/infrastructure:*`, policy scoped to exactly S3 list/get/put/delete on the state bucket, nothing else. Wired to CI via `vars.AWS_TERRAFORM_ROLE_ARN`. Applied by an admin (this root creates the very identity CI would otherwise need to apply it). See its README.

### `01-iam/bootstrap/aws/`

CI role (`openbao-unseal-ci`) scoped to exactly what `02-encryption/aws` needs: full CRUD (create/read/update/**destroy**) on a KMS key + alias (necessarily unscoped by resource — KMS key IDs are random, `kms:CreateKey` has no resource-level permission support) and on an IAM user + access key scoped to the `/openbao/` path (matching that root's `aws_iam_user` path). Also attaches the same state-bucket policy `terraform-state-access` uses — read via a `data.terraform_remote_state` lookup at `00-foundation/aws`, not hardcoded — so this role can read/write the bucket for its own backend too. OIDC-trusted, scoped to `repo:IntegratedDynamic/infrastructure:*`. No general IAM-management capability (can't create roles, can't touch anything outside `/openbao/`), unlike the original `01-iam/bootstrap/aws` this replaces the *name* of but not the *design* of.

### `01-iam/bootstrap/scaleway/`

Standalone root that stands up the **Scaleway IAM identity GitHub Actions uses to authenticate to Scaleway**: a dedicated IAM application + two policies (`Kubernetes`/`VPC`/`PrivateNetworks` FullAccess + `IPAMReadOnly` for cluster management; Object Storage + IAM application/policy management for the storage domain's CI workflow) + an API key, via `modules/scaleway-machine-identity`. GitHub secrets (`SCW_ACCESS_KEY` / `SCW_SECRET_KEY`) are set manually via `gh secret set` (Infisical, which used to carry this, is retired). Keyless GitHub-OIDC → Scaleway is a non-goal — blocked upstream (Scaleway IAM is not an OIDC relying party). See `01-iam/bootstrap/scaleway/README.md`.

### `01-iam/workload/scaleway/`

One `module "identities" { for_each = var.identities }` block (via `modules/scaleway-machine-identity`, single policy per identity — this domain is for simple scoped workload credentials, not CI trust anchors) — `external-dns` today (Scaleway `DomainsDNSFullAccess`, scoped to the project scalepack.fr's zone lives in; no DNS zone/record resource is Terraform-managed here, this root exists purely to provision the identity). Add a future workload identity by adding a map entry to `var.identities`, no new `.tf` resources. `workload_access_key`/`workload_secret_key` outputs stay pinned to `external-dns` specifically (05-secrets/openbao/managed's `terraform_remote_state` reads them) — new identities' keys come from the generic `access_keys`/`secret_keys` map outputs instead. Moved here from `04-dns/scaleway` since it owns no bucket and isn't a CI trust anchor.

### `02-encryption/aws/`

AWS KMS key + a single-purpose IAM user for OpenBao's `seal "awskms"` auto-unseal (OpenBao runs on Scaleway Kapsule, not AWS, so there's no instance profile to lean on — a static AWS access key is required). Standalone domain rather than folded into `05-secrets/openbao/` (different provider/pattern — plain AWS resources, not an OpenBao/Vault-provider resource) or left in `03-storage/scaleway` (not a bucket, not really "storage"). Managed via the `01-iam/bootstrap/aws` role above — see the root's `main.tf` header comment for the full apply-path rationale. Moved here from `06-openbao-unseal/aws` to free up a low domain number.

### `03-storage/scaleway/`

Scaleway tool buckets + their scoped identities: `backup` (OpenBao's own raft snapshots) and `velero` (Kubernetes backups), each with its own bucket AND its own workload identity — kept as separate buckets/identities because Velero writing into a shared bucket broke OpenBao's `s3cmd`-based retention cleanup (confirmed live 2026-07-28). One `module "buckets"` block with `for_each = var.buckets` (via `modules/scaleway-bucket-with-identity`) instantiates every bucket in `main.tf` — add a future tool bucket by adding a map entry to `var.buckets`, no new `.tf` resources. Renamed from `03-backup/scaleway` (which also held the OpenBao unseal KMS resources, now `02-encryption/aws`).

## Conventions

**Branches**: `<type>/<description>` — lowercase, hyphens only. Types: `feature/`, `bugfix/`, `hotfix/`, `ci/`, `chore/`.

**Commits**: Conventional Commits — `<type>[scope]: <description>`. Types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `chore`, `ci`.

**PRs**: After each commit + push on a branch, create a draft PR if none exists. Title: `<type>: description`. Body: context, changes, linked issues (`Closes #123`), test instructions. Use [Conventional Comments](https://conventionalcomments.org/) in reviews (`praise`, `nitpick`, `suggestion`, `issue`, `todo`, `question`, `thought`).

**Terraform workspaces**: a root that runs through CI declares its workspace variables in an `env/` folder — one `env/<name>.tfvars` per workspace. The **filename (without `.tfvars`) is the terraform workspace name** (so state lands at `<workspace_key_prefix>/<name>/<key>`, isolated per root) and the **file contents are that workspace's variable values**. The reusable **composite action `.github/actions/terraform`** takes `root` + `tfvars-file` + `command` (`plan`/`apply`/`destroy`) + `aws-role-arn` (all non-secret inputs) and runs `workspace select <name>` + the command `-var-file=env/<name>.tfvars`, after minting an Infisical OIDC token (skippable) and assuming the AWS role via OIDC. The action takes **no secret inputs**: provider credentials (`SCW_*`, `INFISICAL_MACHINE_IDENTITY_ID`) are read from the job env. The calling **workflow** owns the trigger→command mapping (push → apply, schedule → destroy, else plan), the `concurrency` guard, and the `environment` that scopes credentials — Scaleway keys live in the `scaleway` environment and are exposed to the action as job `env:` (never as plain inputs). The repo must be checked out before calling the action (it is a local action). This replaces the old reliance on a local, gitignored `.terraform/environment` (invisible to CI — a `default`-workspace run collides on the state key).

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
