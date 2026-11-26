# live/ — Terragrunt wiring

Per-environment orchestration of the OpenTofu roots, on top of the code that
stays where it is (`00-foundation/` … `14-sso/`). `live/` only holds *which
root, in which environment, with which state* — never resources.

Out of scope on purpose: the `*/managed` roots applied by Crossplane
(`11-secrets/openbao/managed`, `12-monitoring/grafana/managed`,
`14-sso/managed`) and `00-foundation/aws` (other cloud, one-shot admin apply).

## Layout

```
live/
  root.hcl                          # shared: backend, source, tfvars, lock policy, prune hook
  scripts/prune-cache-copy.sh       # called by root.hcl's after_hook
  dev/<root path>/terragrunt.hcl    # the foundation roots (00-foundation … 13-tailscale)
  staging/10-cluster/scaleway/      # the live homelab cluster
  ephemeral/{env.hcl,10-cluster/scaleway/}   # one cluster + state per PR
  github-pr/10-cluster/kind/        # kind.yml's disposable cluster, local state
```

A unit is `live/<env>/<root path>/terragrunt.hcl`: `live/dev/03-storage/scaleway/` =
root `03-storage/scaleway`, environment `dev`. Everything else is derived from
that path by `root.hcl`:

| Derived value | Rule | Example |
|---|---|---|
| state bucket | `id-terraform-state-<root path, / → ->` (exceptions: `bucket_overrides`) | `id-terraform-state-03-storage-scaleway` |
| state key | `<root path>/<workspace>/terraform.tfstate` | `03-storage/scaleway/03-storage-scaleway-dev/terraform.tfstate` |
| legacy workspace name | `<root path flattened>-<env>` | `03-storage-scaleway-dev` |
| variables | the root's existing `env/<workspace>.tfvars`, verbatim | `03-storage/scaleway/env/03-storage-scaleway-dev.tfvars` |

`<env>/env.hcl` is optional: `locals { name = ... }` renames the environment in the
state key, `tfvars_env` reads another environment's tfvars as the base. Only
`ephemeral` uses it (`name = "pr-<PR_NUMBER>"`, base = `staging`).

## Running it

```bash
export AWS_ACCESS_KEY_ID=$(scw config get access-key)       # state backend creds, same
export AWS_SECRET_ACCESS_KEY=$(scw config get secret-key)   # reason as CLAUDE.md "Setup"

cd live/dev/03-storage/scaleway
terragrunt plan          # or apply / destroy / output / state list …
```

`terragrunt run --all plan` from `live/dev` runs every unit of the environment in
dependency order. Mind two defaults:

- **`run --all apply` auto-approves** in Terragrunt itself. `mise.toml` sets
  `TG_NO_AUTO_APPROVE=true` so it asks per unit. Plan first, apply deliberately.
- **The cluster units are opt-in.** `staging`, `ephemeral` and `github-pr` (paid
  cluster, or Docker + kind) are excluded from `run --all` unless you pass
  `--feature=cluster=true` (the `=` form: with a space the argument reaches
  Terragrunt as one string and is rejected). Run from their own directory they
  always work.

Roots with a real `provider "aws"` (`01-iam/bootstrap/aws`, `02-encryption/aws`) take
the state key pair from `SCALEWAY_STATE_ACCESS_KEY` / `SCALEWAY_STATE_SECRET_KEY`
instead (`explicit_state_credentials_roots` in `root.hcl`), so `AWS_*` stays free
for the provider (`aws sso login`).

### Saved plans

```bash
terragrunt plan -out=$PWD/tfplan     # absolute path: OpenTofu runs in the cache directory
terragrunt apply $PWD/tfplan
```

### An ephemeral cluster by hand

```bash
cd live/ephemeral/10-cluster/scaleway
PR_NUMBER=123 HEAD_REF=<your branch> terragrunt plan      # state 10-cluster-scaleway-pr-123
```

Each PR number gets its own cache directory (`.terragrunt-cache/pr-123`), so
switching `PR_NUMBER` does not trip OpenTofu's "Backend configuration changed".
`PR_NUMBER` defaults to `local`, `HEAD_REF` to nothing (`infra_revision` then
auto-detects the checked-out branch, as for the staging cluster).

## Same state object as before — no migration

The s3 backend keeps a non-default workspace at `<prefix>/<workspace>/<key>`.
Terragrunt runs the **default** workspace with `key` set to that exact full
path, so it reads and writes the very same object (and the same `.tflock`).
Nothing was moved, copied or deleted in any bucket, and cross-root readers
(`terraform_remote_state` in `11-secrets/openbao/managed` and the cluster roots,
tfvars `*_state_key`) are unaffected.

Consequence for a root that used `terraform.workspace` in resource names
(`01-iam/workload/scaleway`, `02-encryption/aws`, `03-storage/scaleway`): under
Terragrunt that value is `default`. Such a root takes a `workspace_name`
variable instead, set from the unit's `inputs`. Check that `plan` shows **no
changes** before anything else — a different name renames live IAM resources.

## Adding / migrating a root

1. `live/<env>/<root path>/terragrunt.hcl` with the `include "root"` block (see
   `dev/03-storage/scaleway/`), plus `inputs` for anything that is not in the
   root's tfvars.
2. In the root: delete its `backend "s3"` block (now generated), replace any
   `terraform.workspace` by a variable. A `.terraform/` left in the root's
   directory by the old workflow still caches the removed backend and makes a
   bare `tofu init` there fail with "No valid credential sources found": delete
   it once (`rm -rf <root>/.terraform`). It is a local cache, CI never has it.
3. `terragrunt plan` → expect `No changes`. Never apply a migration that does
   not start from that. For a root you cannot plan (no credentials for its
   provider), compare what `terragrunt state pull` reads with the S3 object at
   the old `<prefix>/<workspace>/<key>`: same `serial`, `lineage` and resource
   count means the same state.

## Things worth knowing

- **Bare `tofu` in a migrated root uses a local, empty state.** The backend only
  exists through Terragrunt. Roots that need `workspace_name` fail fast without
  it, which is the safety net; don't rely on it, use `terragrunt`.
- **Lock files** stay in the root's own directory (`copy_terraform_lock_file =
  false`): `mise run lock` and the `Verify OpenTofu Lock Files` workflow are
  unchanged. A provider added in a root still needs `mise run lock`.
- **Backend bootstrap is off** (`disable_init = true`): the buckets come from
  `00-foundation/scaleway`, Terragrunt must not create or alter them.
- **Source copy**: `terraform.source` uses `//` at the repo root so `../../modules`,
  `platform-apps/` and `files/` resolve inside Terragrunt's cache copy. That copies
  the **whole repo**, gitignored files included. `root.hcl`'s `after_hook` runs
  `scripts/prune-cache-copy.sh` on the copy right after: it drops `generated/`
  (WireGuard private keys), `*.conf` and every `*.auto.tfvars` except the root's
  own (the `local.auto.tfvars` override of `10-cluster/scaleway`). The script
  refuses any path outside a `.terragrunt-cache`, so it cannot touch the real
  tree. The cache lives in `.terragrunt-cache/` (gitignored).
- **The cluster root keeps its `terraform_remote_state` reads**: their outputs are
  `sensitive`, which a Terragrunt `dependency` → `inputs` hand-over would drop.
  The units only declare `dependencies` for ordering.
- **Terragrunt logs go to stderr**, tofu's output to stdout, so
  `terragrunt state list | …` and `terragrunt output -json | jq` work as with `tofu`.
- **In CI**, `.github/actions/terraform` takes a `unit` input; `kind.yml` uses only
  `.github/actions/setup-terragrunt` (pinned release, checksum-verified; keep its
  version in step with `mise.toml`).
