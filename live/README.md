# live/ — Terragrunt wiring

Orchestration of the OpenTofu roots, on top of the code that stays where it is
(`00-foundation/` … `14-sso/`). `live/` only holds *which root, for which core or
cluster, with which state* — never resources.

Out of scope on purpose: the `*/managed` roots applied by Crossplane
(`11-secrets/openbao/managed`, `12-monitoring/grafana/managed`,
`14-sso/managed`).

## Layout

```
live/
  root.hcl                          # shared by every unit: source, tfvars, backend
  types/<type>.hcl                  # recipe of a cluster type: features and size
  core/main/<root path>/            # a core: what a cluster needs to exist
  core/main/wiring.hcl              # what is specific to this core (domain, certificates)
  clusters/
    core.hcl                        # shared: the link from a cluster to its core
    staging/{cluster.hcl,10-cluster/scaleway/}     # the homelab, *.staging.scalepack.fr
    ephemeral/{cluster.hcl,10-cluster/scaleway/}   # one cluster + state per PR
    kind/{cluster.hcl,10-cluster/kind/}            # kind.yml's disposable cluster, local state
```

A unit is `live/core/<core>/<root path>/` or `live/clusters/<cluster>/<root path>/`.
`root.hcl` derives everything else from that path (the **instance** is `main`,
`staging`, ...):

| Derived value | Rule | Example |
|---|---|---|
| state bucket | `id-terraform-state-<root path, / → ->` | `id-terraform-state-03-storage-scaleway` |
| state key | `<root path>/<instance>/terraform.tfstate` | `03-storage/scaleway/main/terraform.tfstate` |
| variables (if the root has that file) | `env/<root path flattened>-<instance>.tfvars` | `03-storage/scaleway/env/03-storage-scaleway-main.tfvars` |
| `workspace_name` input | `<root path flattened>-<instance>` (names live IAM resources) | `03-storage-scaleway-main` |

## Which cluster uses which core

One line, in the cluster's `cluster.hcl`:

```hcl
locals {
  core = "main"
}
```

Its units include `clusters/core.hcl`, which derives from that value both the run
order (`dependencies`) and the state bucket/key of every core root the cluster
reads. Neither is written anywhere else. A cluster with no core would declare none
and not include `core.hcl`. A second core is a new folder under `core/`, with its
own tfvars (`env/<root>-<core>.tfvars`); buckets are shared per root, the key
separates the cores.

`cluster.hcl` may also set `name`, which renames the instance. Only `ephemeral`
does (`pr-<PR_NUMBER>`).

## What a cluster is made of

The Scaleway clusters have no tfvars. Their variables are Terragrunt `inputs`:

| Where | Says | Example |
|---|---|---|
| `types/main.hcl` | the recipe: features (`domains`), size, certificate authority (`letsencrypt_staging`) | every `main`-like cluster |
| `core/<core>/wiring.hcl` | what differs between cores, added by `clusters/core.hcl` | `domain` |
| the unit | the cluster's own identity | `cluster_name` |

A unit includes `root`, `core` and its type. Precedence, lowest first: `inputs`,
then a root's `*.auto.tfvars` or `env/` file, then `-var` (how `ephemeral`
overrides them). `kind` still has its own tfvars.

## Running it

```bash
export AWS_ACCESS_KEY_ID=$(scw config get access-key)       # state backend creds, same
export AWS_SECRET_ACCESS_KEY=$(scw config get secret-key)   # reason as CLAUDE.md "Setup"

cd live/core/main/03-storage/scaleway
terragrunt plan          # or apply / destroy / output / state list …
```

`terragrunt run --all plan` from `live/core/main` runs every unit of that core in
dependency order. Mind two defaults:

- **`run --all apply` auto-approves** in Terragrunt itself. `mise.toml` sets
  `TG_NO_AUTO_APPROVE=true` so it asks per unit. Plan first, apply deliberately.
- **The cluster units are opt-in.** Everything under `clusters/` (paid
  cluster, or Docker + kind) are excluded from `run --all` unless you pass
  `--feature=cluster=true` (the `=` form: with a space the argument reaches
  Terragrunt as one string and is rejected). Run from their own directory they
  always work.

Credentials are the same rule for every unit: `AWS_ACCESS_KEY_ID` /
`AWS_SECRET_ACCESS_KEY` are the Scaleway **state** key. A root with a real
`provider "aws"` authenticates with the CLI profile named by `aws_profile` in its
tfvars (an explicit profile wins over those variables), so run
`aws sso login --profile infrastructure` first.

### Saved plans

```bash
terragrunt plan -out=$PWD/tfplan     # absolute path: OpenTofu runs in the cache directory
terragrunt apply $PWD/tfplan
```

### An ephemeral cluster by hand

```bash
cd live/clusters/ephemeral/10-cluster/scaleway
PR_NUMBER=123 HEAD_REF=<your branch> terragrunt plan      # instance pr-123
```

Each PR number gets its own cache directory (`.terragrunt-cache/pr-123`), so
switching `PR_NUMBER` does not trip OpenTofu's "Backend configuration changed".
`PR_NUMBER` defaults to `local`, `HEAD_REF` to nothing (`infra_revision` then
auto-detects the checked-out branch, as for the staging cluster).

## Adding a root

1. Create the unit with the `include "root"` block (see
   `core/main/03-storage/scaleway/`); a cluster unit also includes `core.hcl`.
2. Add `env/<root path flattened>-<instance>.tfvars` in the root (or `inputs`, see
   above), and its bucket in `00-foundation/scaleway`'s `state_buckets`. The root has no `backend` block.
3. `terragrunt plan`.

Moving a unit or renaming an instance changes its state key: copy the state object
to the new key (an S3 copy keeps `lineage` and `serial`; `state push` into an
empty destination does not) and start from a `plan` with no destroy. A name built
from `workspace_name` also renames live resources.

## Things worth knowing

- **Bare `tofu` in a root uses a local, empty state.** The backend only
  exists through Terragrunt. Roots that need `workspace_name` fail fast without
  it, which is the safety net; don't rely on it, use `terragrunt`.
- **Lock files** stay in the root's own directory (`copy_terraform_lock_file =
  false`): `mise run lock` and the `Verify OpenTofu Lock Files` workflow are
  unchanged. A provider added in a root still needs `mise run lock`.
- **Backend bootstrap is off** (`disable_init = true`): the buckets come from
  `00-foundation/scaleway`, Terragrunt must not create or alter them.
- **Source copy**: `terraform.source` uses `//` at the repo root so `../../modules`,
  `platform-apps/` and `files/` resolve inside Terragrunt's cache copy.
  `exclude_from_copy` keeps `generated/` (WireGuard private keys), `*.conf`,
  `*.auto.tfvars` and state files out of it. A root's own `*.auto.tfvars` (the
  `local.auto.tfvars` override of `10-cluster/scaleway`) are passed as
  `-var-file` from the real tree, below the env tfvars in precedence.
- **The cluster root keeps its `terraform_remote_state` reads**: their outputs are
  `sensitive`, which a Terragrunt `dependency` → `inputs` hand-over would drop.
  The units only declare `dependencies` for ordering.
- **Terragrunt logs go to stderr**, tofu's output to stdout, so
  `terragrunt state list | …` and `terragrunt output -json | jq` work as with `tofu`.
- **In CI**, `.github/actions/terraform` takes a `unit` input. OpenTofu and
  Terragrunt come from `mise.toml` through `jdx/mise-action`.
