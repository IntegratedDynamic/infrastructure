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
  root.hcl                          # shared: backend, source, tfvars, lock policy
  <env>/<root path>/terragrunt.hcl  # one unit = one root in one environment
```

`live/dev/03-storage/scaleway/` = root `03-storage/scaleway`, environment `dev`.
Everything else is derived from that path by `root.hcl`:

| Derived value | Rule | Example |
|---|---|---|
| state bucket | `id-terraform-state-<root path, / → ->` (exceptions: `bucket_overrides`) | `id-terraform-state-03-storage-scaleway` |
| state key | `<root path>/<workspace>/terraform.tfstate` | `03-storage/scaleway/03-storage-scaleway-dev/terraform.tfstate` |
| legacy workspace name | `<root path flattened>-<env>` | `03-storage-scaleway-dev` |
| variables | the root's existing `env/<workspace>.tfvars`, verbatim | `03-storage/scaleway/env/03-storage-scaleway-dev.tfvars` |

## Running it

```bash
export AWS_ACCESS_KEY_ID=$(scw config get access-key)       # state backend creds, same
export AWS_SECRET_ACCESS_KEY=$(scw config get secret-key)   # reason as CLAUDE.md "Setup"

cd live/dev/03-storage/scaleway
terragrunt plan          # or apply / destroy / output …
```

`terragrunt run --all plan` from `live/dev` runs every unit of the environment,
in dependency order once units declare `dependency` blocks.

## Same state object as before — no migration

The s3 backend keeps a non-default workspace at `<prefix>/<workspace>/<key>`.
Terragrunt runs the **default** workspace with `key` set to that exact full
path, so it reads and writes the very same object (and the same `.tflock`).
Nothing was moved, copied or deleted in any bucket, and cross-root readers
(`terraform_remote_state` in `11-secrets/openbao/managed`, tfvars `*_state_key`)
are unaffected.

Consequence for a root that used `terraform.workspace` in resource names
(`03-storage/scaleway`, `01-iam/workload/scaleway`): under Terragrunt that value
is `default`. Such a root takes a `workspace_name` variable instead, set from the
unit's `inputs`. Migrate one the same way, and check `plan` shows **no changes**
before anything else — a different name renames live IAM resources.

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
   not start from that.

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
  `platform-apps/` and `files/` resolve inside Terragrunt's cache copy. Cache
  lives in `.terragrunt-cache/` (gitignored).
