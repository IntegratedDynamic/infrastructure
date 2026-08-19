# 00-foundation/scaleway — what this domain is for

A Scaleway Object Storage counterpart to `00-foundation/aws`'s S3 bucket. As
of 2026-08-19, every root in this repo's state lives here **except**
`00-foundation/aws` itself (which stays on AWS permanently — it IS the AWS
bucket, see its own README). Before this migration, every root used that one
shared AWS bucket (different `workspace_key_prefix` per root, same bucket).

## Why per-root buckets, not one shared bucket

The AWS foundation bucket is **one bucket, many prefixes** — every root
writes to `<workspace_key_prefix>/<workspace>/terraform.tfstate` inside it,
and the one `terraform-state-access` IAM role is scoped (via its policy) to
that bucket only.

Scaleway can't reproduce that isolation: IAM policy rules here scope to a
**project**, not a bucket or an object prefix (see
`modules/scaleway-bucket-with-identity`'s `identity_permission_set_names`
comment — the same limitation this repo already documents elsewhere). Any
identity granted Object Storage permissions in a project can read/write
**every** bucket in that project regardless of prefix. A shared bucket would
therefore give every consuming root's CI identity read/write on every other
root's state object, with no way to scope it down further — strictly worse
than the AWS setup's already-documented "no isolation between roots" trade-off,
since there it's at least contained to CI-assumed-role-in-this-repo.

So: **one dedicated bucket per consuming root module** (`var.state_buckets`
below, one map entry per root), each with its **own** dedicated identity by
default too (`create_identity = true`, see "Per-bucket identities" below) —
it doesn't fix the underlying project-level IAM limitation (that identity
can still technically touch every bucket in the project, Scaleway gives no
way to scope it down further), but it at least means a bucket — and its
identity — can be deleted/recreated/reused/revoked independently per root,
and keeps each root's state blast radius (accidental `force_destroy`,
lifecycle misconfig, a leaked key, etc.) confined to its own bucket. Most
roots need exactly one bucket; a root with its own bootstrap/init concerns
(e.g. something needing a scratch bucket before its "real" one exists) can
get more than one entry.

## Status: migration complete (2026-08-19)

This root's own state is self-hosted here too
(`state_buckets["foundation_scaleway"]`) — bootstrapped the same one-time
chicken-and-egg way `00-foundation/aws` was: created while its state still
lived in the AWS bucket, then repointed at itself and migrated with
`terraform init -migrate-state`.

**Rehearsal result (2026-08-18): confirmed working.** The migration procedure
was rehearsed end to end first against a throwaway root, `99-scratch/migration-test`
(applied against the AWS bucket, repointed at this root's
`state_buckets["scratch"]` bucket, moved with `terraform init -migrate-state`,
verified, then destroyed and its directory deleted from the repo — its purpose
was purely this rehearsal). Findings:

- **Locking works.** `backend "s3" { use_lockfile = true }` (conditional
  `If-None-Match` writes) succeeded on Scaleway Object Storage — both during
  the migration itself and on a subsequent `plan` ("Acquiring state
  lock"/"Releasing state lock", no errors). No fallback locking strategy
  needed.
- **Credential wiring confirmed.** Terraform's `s3` backend authenticates
  with `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` — the exact same env
  vars a root's own `provider "aws"` block (if it has one, e.g.
  `02-encryption/aws`) uses for its *real* AWS credentials. The working
  approach: pass the Scaleway key pair via `-backend-config="access_key=..."`
  / `-backend-config="secret_key=..."` (from a gitignored file, never
  committed) at `terraform init`, leaving ambient `AWS_ACCESS_KEY_ID`/
  `AWS_SECRET_ACCESS_KEY` free for a real AWS provider. Still needs
  `.github/actions/terraform/action.yml` updated to do this for CI before any
  such root migrates — out of scope for this rehearsal, in scope for the real
  rollout.
- **Endpoint/path style confirmed.** Scaleway's S3-compatible endpoint is
  path-style (`https://s3.<region>.scw.cloud/<bucket>`, per
  `modules/scaleway-bucket-with-identity`'s `bucket_endpoint` output), not
  AWS's virtual-hosted style — `use_path_style = true` plus
  `skip_s3_checksum = true` (Scaleway doesn't support the AWS SDK's newer
  default PutObject checksum) were both required. The working `backend "s3"`
  block (now gone along with the deleted rehearsal root):

  ```hcl
  backend "s3" {
    bucket                       = "<per-root bucket from state_buckets>"
    region                       = "fr-par"
    key                          = "terraform.tfstate"
    encrypt                      = true
    use_lockfile                 = true
    skip_credentials_validation  = true
    skip_region_validation       = true
    skip_requesting_account_id   = true
    skip_s3_checksum              = true
    use_path_style                = true
    endpoints = {
      s3 = "https://s3.fr-par.scw.cloud"
    }
  }
  ```

**Real rollout (2026-08-19): every domain migrated.** Same procedure, applied
to every real root in one session: `01-iam/bootstrap/aws`,
`01-iam/bootstrap/scaleway`, `01-iam/workload/scaleway`, `02-encryption/aws`,
`03-storage/scaleway`, `04-vpn/wireguard-exit`,
`04-vpn/wireguard-site-to-site`, `05-secrets/openbao/bootstrap`,
`05-secrets/openbao/managed`, `06-monitoring/grafana/bootstrap`,
`06-monitoring/grafana/managed`, `10-cluster/scaleway`, plus this root
itself. Every `data "terraform_remote_state"` cross-root read (~11 of them)
was repointed and parametrized too — bucket/key are now variables set in
`env/*.tfvars`, not hardcoded literals. `10-cluster/local` has no backend of
its own (local state) but its two cross-root reads (of `03-storage/scaleway`
and `02-encryption/aws`) were fixed the same way, so it doesn't read a stale
AWS-side copy.

One pre-existing, unrelated drift was surfaced (not caused) by the
migration: `03-storage/scaleway`'s `loki`/`tempo` buckets' live
`expiration.days` is still 30, while the code (since commit
"fix(storage): drop Loki + Tempo bucket retention to 1 day") says 1 — that
commit was never actually applied. Left alone; not this migration's job to
fix.

**Known follow-up, not yet done**: `.github/actions/terraform/action.yml`
still only assumes an AWS role for backend state R/W. Every migrated root's
GitHub Actions workflow needs that updated to pass Scaleway credentials via
`-backend-config` instead — locally this was done per-command with an
explicit `-backend-config=<gitignored file>`, keeping ambient
`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` free for roots with a real
`provider "aws"` block (`02-encryption/aws`, `01-iam/bootstrap/aws`) — those
two need real AWS credentials for their own resources regardless of where
their backend lives, and would collide with Scaleway backend credentials in
the same env vars.

**The rehearsal's bucket is intentionally still here.** `state_buckets["scratch"]`
below, and the live `id-terraform-state-99-scratch-migration-test` bucket it
provisions, are left in place on purpose — `prevent_destroy` included, not to
be flipped off or worked around. Its cleanup is a manual admin action, on the
admin's own timeline, once they're satisfied it's no longer needed. Do not
remove the entry or the bucket without being explicitly asked to.

## Per-bucket identities (2026-08-19)

Originally this root created ONE shared `terraform-state-access` identity
for every bucket (Scaleway IAM can't scope below project level anyway, so a
shared identity seemed harmless). Redesigned to reuse
`modules/scaleway-bucket-with-identity` instead — the same module
`03-storage/scaleway` already uses — via `for_each` over `var.state_buckets`,
giving each bucket its **own** dedicated identity by default:

- `create_identity` (module variable, default `true`) toggles whether a
  given `state_buckets` entry gets its own identity. A root that needs
  broader Scaleway rights than "CRUD on my own state bucket" gets its
  identity in `01-iam/` instead and sets this `false` — this module call
  stays the common case, not the only case.
- Identity application/policy names and descriptions are **generated**, not
  supplied — derived from `bucket_name` (itself already globally unique on
  Scaleway), truncated defensively to Scaleway's 64-rune IAM name limit.
  Unique-by-construction, no random suffix needed, and traceable back to
  its bucket at a glance (e.g. `id-terraform-state-03-storage-scaleway-access`).
- The module itself gained two changes to support this: `expiration_enabled`
  (default `true`, matching its prior behavior — state buckets set it
  `false` since their current-version object must never expire) and
  `create_identity` with a `moved` block (`modules/scaleway-bucket-with-identity/moves.tf`)
  so adding `count` to the identity submodule didn't force
  `03-storage/scaleway`'s existing live identities to destroy/recreate.

**Incident during the switchover**: destroying the old shared identity and
creating the 14 new ones in the same `apply` briefly cut off this root's
*own* backend authentication mid-apply (it was using the shared identity's
key via `-backend-config`) — `terraform` lost its S3 credentials partway
through, leaving one policy resource uncreated and the state lock stuck.
Recovered by re-`init`-ing with the `scw` CLI's own (human/admin) API key via
`-backend-config` to regain read/write, `force-unlock`-ing the stale lock,
then re-`apply`-ing to finish. Lesson: a root's own backend and any identity
*it itself* provisions are circular if the backend depends on that identity
— fine for a one-time redesign like this, but don't wire ongoing CI through
a root's own self-provisioned identity for its own backend without a
recovery path (the `scw` CLI's admin key filled that role here).

After the swap, every already-migrated root's **local** cached backend
credentials (each `.terraform/terraform.tfstate` pointer, populated at
`init -backend-config` time) still pointed at the now-destroyed shared key —
each was re-`init -reconfigure`d with its own new dedicated identity's
key/secret (fetched from this root's `access_keys`/`secret_keys` outputs) to
restore local operability. Nothing CI-facing was affected (the composite
action doesn't use any of this yet — see the follow-up above).

## Cross-root reads need no manual credential setup

Every `data "terraform_remote_state"` reading a Scaleway-hosted bucket (see
"Real rollout" above — `10-cluster/local`, `10-cluster/scaleway`,
`05-secrets/openbao/managed`, `06-monitoring/grafana/bootstrap`,
`06-monitoring/grafana/managed`) authenticates via a `data "external"`
block that shells out to `scw config get access-key`/`secret-key` — the
*exact same* credentials `provider "scaleway" {}` already uses implicitly
everywhere in this repo. An admin who already has `scw` configured (already
a repo-wide prerequisite) needs zero extra setup: no env var to export, no
narrow Terraform-managed identity to fetch and paste in. This deliberately
avoids requiring `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` set ambiently —
first tried, then dropped: it worked, but meant fetching one specific
bucket's dedicated identity key by hand every session, real unnecessary
friction for someone who's already a full Scaleway admin on their own
machine. Confirmed working with zero ambient credentials set (2026-08-19).

## The contract

Same four requirements as `00-foundation/aws`'s README (durable+versioned
store, concurrent-write protection, one narrowly-scoped CI identity, must be
runnable locally by an admin) — see that README for the full text. This root
satisfies them the same way, Scaleway-native:

1. `scaleway_object_bucket` per `var.state_buckets` entry, versioning on,
   SSE-AES256, `prevent_destroy`, and a lifecycle rule that expires only
   **noncurrent** versions — the current state object is never expired.
2. `use_lockfile = true` on every consuming root's backend block — confirmed
   working against Scaleway (see rehearsal findings above).
3. One Scaleway IAM application + static API key **per bucket**, by default
   (`modules/scaleway-bucket-with-identity`, see "Per-bucket identities"
   above) — keyless OIDC isn't available (Scaleway IAM isn't an OIDC relying
   party, see `01-iam/bootstrap/scaleway/README.md`). Project-scoped Object
   Storage R/W, same documented limitation as above (a project-level grant,
   not true per-bucket isolation — this repo's IAM ceiling on Scaleway, not
   an oversight here).
4. Applied locally by an admin, same as `00-foundation/aws` and every
   Scaleway root today (`provider "scaleway" {}` — creds/project from the
   `scw` CLI config).
