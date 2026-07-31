# 00-foundation/aws — Terraform state bucket + CI's AWS access

The AWS implementation of the `00-foundation` contract — see
[`../README.md`](../README.md) for what that contract is and why this domain
is named after its role, not "remote_state" or "aws". Read that first; this
file is the how, not the why.

It provisions:

1. A single **AWS S3 bucket** holding the Terraform remote state for the
   **whole org**. Every other root points its `backend "s3"` at this bucket.
2. The **GitHub OIDC provider** + the **one AWS IAM role**
   (`terraform-state-access`) every GitHub Actions workflow in this repo
   assumes to read/write that bucket — see [CI's AWS access](#cis-aws-access).

Merged from three former roots (`00-remote_state`, `01-iam/bootstrap/aws`,
`01-iam/ci-managed/aws-state-access`) that were all fundamentally the same
foundation concern living in separate places for historical reasons. Applied
by an admin (this root creates the very identity CI would otherwise need to
apply it).

## What it creates

### The state bucket

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

### CI's AWS access

`ci-role.tf` creates the GitHub OIDC provider and one role,
`terraform-state-access` — trusted via OIDC scoped to
`repo:IntegratedDynamic/infrastructure:*` only, with an inline policy granting
**exactly** `s3:ListBucket`/`GetBucketVersioning`/`GetBucketLocation` on the
bucket and `s3:GetObject`/`PutObject`/`DeleteObject` on its contents. Nothing
else — no IAM management capability, no ability to create or modify any other
role or policy.

This replaces two former roots that together built a much larger "CI can
safely mint further IAM roles" system: a permissions boundary ("admin minus a
hardened deny-list") plus a policy letting the CI role create/attach other
roles under a managed path, specifically so it could mint the one role that
actually did the state R/W. That entire guardrail had exactly one consumer.
Once the role's own job is narrowed to "read/write this bucket," there's no
IAM-management capability left to guard against escalating in the first
place, so the guardrail system is gone along with it.

Every workflow in `.github/workflows/` assumes this one role (via
`vars.AWS_TERRAFORM_ROLE_ARN`) for every root's `plan`/`apply`/`destroy` — see
the composite action in `.github/actions/terraform/`.

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
   terraform -chdir=00-foundation/aws init
   terraform -chdir=00-foundation/aws apply   # creates the bucket (billable)
   ```
3. Re-add the `backend "s3"` block and migrate the local state into the bucket
   it now manages:
   ```bash
   terraform -chdir=00-foundation/aws init -migrate-state
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
