# terraform-state-bucket

A standalone Terraform root that provisions a single **AWS S3 bucket** to hold
the Terraform remote state for the **whole org**. Every other root
(`cluster/local/`, `cluster/scaleway/`, `github-ci/`, and future ones) points
its `backend "s3"` at this bucket.

This is intentionally **not** under `cluster/` because it provisions no cluster;
it is the shared substrate the other roots depend on. It lives at the repo root
as its own root module.

## What it creates

A single S3 bucket (default name `id-terraform-state`, override with
`-var bucket_name=...`) via the community
[`terraform-aws-modules/s3-bucket`](https://registry.terraform.io/modules/terraform-aws-modules/s3-bucket/aws/latest)
module, configured for state storage:

- **Versioning enabled** — recover from a corrupt/truncated state push.
- **SSE-S3 encryption** (AES256) — every object encrypted at rest, no KMS key to
  manage.
- **`BucketOwnerEnforced`** + **public-access block** — ACLs disabled and all
  public access blocked; the bucket and its objects are unreachable anonymously.
- **TLS-only bucket policy** — non-HTTPS requests are denied.
- **Lifecycle rule** — expires *noncurrent* (superseded) versions after 10 days
  (override with `-var noncurrent_version_expiration_days=...`); the current
  version is never expired.
- **`force_destroy = false`** — guards against deleting everyone's state.

State **locking** uses Terraform's native S3 lockfile (`use_lockfile`, GA since
Terraform 1.10) — a `.tflock` object written next to the state. No DynamoDB lock
table is needed.

## Credentials

The AWS provider **and** the S3 backend resolve credentials through the standard
AWS SDK chain — nothing is hardcoded in the `.tf`. The same code authenticates
two different ways depending on where it runs:

| | Source | Setup |
|---|---|---|
| **Local** | AWS SSO | `aws sso login --profile infrastructure` then `export AWS_PROFILE=infrastructure` |
| **CI** | GitHub OIDC | `aws-actions/configure-aws-credentials` exchanges the OIDC token for STS creds and exports them as env vars |

Because STS env vars sit at the top of the SDK chain, CI needs no provider
changes — only the `id-token: write` permission and the configure-credentials
step in the workflow.

## Bootstrapping (chicken-and-egg)

This root creates the very bucket it then stores its state in. Bootstrap order:

1. Log in and select the profile:
   ```bash
   aws sso login --profile infrastructure
   export AWS_PROFILE=infrastructure
   ```
2. Apply once with **local state** — temporarily comment out the `backend "s3"`
   block in `version.tf` so the bucket gets created:
   ```bash
   terraform -chdir=terraform-state-bucket init
   terraform -chdir=terraform-state-bucket apply   # creates the bucket (billable)
   ```
3. Re-add the `backend "s3"` block and migrate the local state into the bucket
   it now manages:
   ```bash
   terraform -chdir=terraform-state-bucket init -migrate-state
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
    region = "eu-west-3"

    # Per-root prefix; non-default workspaces land under <prefix>/<name>/<key>.
    workspace_key_prefix = "cluster/scaleway"

    encrypt      = true
    use_lockfile = true
  }
}
```

> **Note — `bucket_name` and `region` do not flow into the backend.** Terraform
> backend blocks cannot reference variables, so `bucket` and `region` are
> hardcoded in every `backend "s3"` block (including this root's own
> `version.tf`). The variables only affect the bucket *resource*. If you ever
> change the bucket name or region, you must update those backend blocks by
> hand. In practice you don't rename the state bucket often, so this is a minor
> day-to-day caveat.
