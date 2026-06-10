# state-backend

A standalone Terraform root that provisions a single **Scaleway Object Storage
bucket** to hold the Terraform remote state for the **whole org**. Every other
root (`cluster/local/`, `cluster/scaleway/`, and future ones) points its
`backend "s3"` at this bucket — Scaleway's Object Storage is S3-compatible.

This is intentionally **not** under `cluster/` because it provisions no cluster;
it is the shared substrate the cluster roots depend on. It lives at the repo
root as its own root module.

## What it creates

- `scaleway_object_bucket.tfstate` — the state bucket (default name
  `id-terraform-state`, override with `-var bucket_name=...`). Bucket names are
  globally unique across Scaleway.
  - **Versioning enabled** — lets you recover from a corrupt/truncated state push.
  - **Lifecycle rule** — expires *noncurrent* (superseded) versions after 10 days
    (override with `-var noncurrent_version_expiration_days=...`); the current
    version is never expired.
  - **`prevent_destroy`** — guards against accidentally deleting everyone's state.
- `scaleway_object_bucket_acl.tfstate` — `private` ACL, which keeps the bucket
  and all its objects unreachable by anonymous/public requests.

## Credentials

Like `cluster/scaleway/`, the Scaleway provider reads credentials and the
default region/project from the **scw CLI config** (`~/.config/scw/config.yaml`).
Nothing is set in tfvars.

## Bootstrapping (chicken-and-egg)

This root creates the very bucket it then stores its state in. Bootstrap order:

1. Apply once with **local state** (comment out / remove the `backend "s3"` block
   in `version.tf`) so the bucket gets created:
   ```bash
   terraform -chdir=state-backend init
   terraform -chdir=state-backend apply   # creates the bucket (billable)
   ```
2. Re-add the `backend "s3"` block (already present in `version.tf`) and migrate
   the local state into the bucket it now manages:
   ```bash
   terraform -chdir=state-backend init -migrate-state
   ```

After that, this root's own state lives at `state-backend/terraform.tfstate`
inside the bucket, just like every other root.

## Pointing another root at this bucket

Add a `backend "s3"` block to the consuming root and run `terraform init`
(`-migrate-state` if it already has local state). Give each root a distinct
`key` *and* `workspace_key_prefix` so its state (and workspaces) stay separate
inside the one shared bucket.

```hcl
terraform {
  backend "s3" {
    bucket = "id-terraform-state"
    key    = "cluster/scaleway/terraform.tfstate" # per-root; pick a unique path
    region = "fr-par"

    # Per-root prefix; non-default workspaces land under <prefix>/<name>/<key>.
    workspace_key_prefix = "cluster/scaleway"

    endpoints = { s3 = "https://s3.fr-par.scw.cloud" }

    # Disable the backend's AWS-only preflight checks (IMDS, STS account-id,
    # region allowlist): Scaleway speaks the S3 API but isn't AWS itself.
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
  }
}
```

> **Note — `bucket_name` and `region` do not flow into the backend.** Terraform
> backend blocks cannot reference variables, so `bucket`, `region` and the s3
> `endpoints` URL are hardcoded in every `backend "s3"` block (including this
> root's own `version.tf`). The `bucket_name` / `region` variables only affect
> the bucket *resource*. If you ever change the bucket name or region, you must
> update those backend blocks by hand — otherwise Terraform reads/writes state
> against the old location. In practice you don't rename the state bucket often,
> so this is a minor day-to-day caveat.

The S3 backend authenticates with AWS-style env vars (it does **not** read the
scw CLI config, unlike the Scaleway provider). Derive them from your scw config
before `init`/`plan`/`apply`:

```bash
export AWS_ACCESS_KEY_ID="$(scw config get access-key)"
export AWS_SECRET_ACCESS_KEY="$(scw config get secret-key)"
```

The repo's `mise.toml` already injects these via an `[env]` block, so under mise
(`mise run ...`, or any shell with `mise activate`) it's handled automatically.
