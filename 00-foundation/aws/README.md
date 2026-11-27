# 00-foundation/aws — Terraform state bucket + CI's AWS access

The AWS implementation of the `00-foundation` contract — see
[`../README.md`](../README.md) for what that contract is and why this domain
is named after its role, not "remote_state" or "aws". Read that first; this
file is the how, not the why.

It provisions:

1. A single **AWS S3 bucket**, which held the Terraform remote state for the
   whole org before every root moved to Scaleway (see [State](#state)).
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

## State

This root's state lives in Scaleway
(`id-terraform-state-00-foundation-aws`, created by `00-foundation/scaleway`),
wired by Terragrunt like every other root, so there is no chicken-and-egg left:

```bash
aws sso login --profile infrastructure
export AWS_ACCESS_KEY_ID=$(scw config get access-key)       # the state backend
export AWS_SECRET_ACCESS_KEY=$(scw config get secret-key)
cd live/dev/00-foundation/aws
terragrunt plan
```

The AWS provider uses the profile named by `aws_profile` in
`env/00-foundation-aws-dev.tfvars`.

The AWS bucket above still exists and is still what `terraform-state-access`
grants; it holds the previous copies of the states that used to live there.
