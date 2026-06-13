# aws-github-oidc

A standalone Terraform root that provisions **keyless GitHub-OIDC → AWS** access
for this repo's CI: an IAM OIDC identity provider, plus an IAM role GitHub
Actions assumes (via short-lived OIDC tokens) to read/write the Terraform
**remote state on AWS S3** — **no static AWS keys in GitHub secrets**.

This is **not** under `cluster/` — it provisions no cluster. It's a CI-platform
concern, kept as its own root so its state and blast radius stay small.

## Why OIDC here (and why Scaleway still uses a static key)

The Terraform state backend was migrated from Scaleway Object Storage to real
**AWS S3** (`eu-west-3`, Paris). AWS IAM **is** an OIDC relying party, so the
ideal keyless flow works: GitHub mints a short-lived OIDC token, AWS STS trades
it for temporary credentials by assuming a scoped role — nothing long-lived in
GitHub secrets.

Scaleway resources (Kapsule, VPC) are a different story: **Scaleway IAM is not an
OIDC relying party** ([feature request](https://feature-request.scaleway.com/posts/761/oidc-provider-for-external-ci-cd)),
so those keep using a scoped, static Scaleway API key (see `terraform-ci/` /
`github-ci/`). OIDC here covers **only** the AWS/S3 side. Revisit Scaleway OIDC
if/when Scaleway ships it.

All resources are built from the [`terraform-aws-modules/iam`](https://registry.terraform.io/modules/terraform-aws-modules/iam/aws/latest)
modules (`iam-oidc-provider`, `iam-role`, `iam-policy`).

## What it creates

- **OIDC provider** (`iam-oidc-provider`) — the GitHub Actions OIDC issuer
  (`https://token.actions.githubusercontent.com`, audience `sts.amazonaws.com`).
  **One per AWS account** — if one already exists, import it rather than
  duplicating.
- **CI role** `github-actions-terraform` (`iam-role`, `enable_github_oidc`) — the
  role CI assumes. Its **trust policy** is scoped to exactly this repo
  (`repo:IntegratedDynamic/infrastructure:*`), so only this repo's workflows can
  assume it. Permissions come from the CI grant below.
- **CI grant** `tf-managed-ci` (`iam-policy`) — a tight policy: Terraform state
  R/W on the state bucket only, plus **privilege-escalation-safe** IAM role
  management (see next section). The S3-native lock (`use_lockfile = true`) rides
  on object R/W, so no DynamoDB table is needed.
- **Permissions boundary** `tf-managed-boundary` (`iam-policy`) — the ceiling
  attached to every role the CI creates.

Outputs `role_arn`, `permissions_boundary_arn`, and `managed_path` are all public
identifiers, not secrets.

## Creating IAM roles from CI — the permissions-boundary contract

The CI role can run `terraform apply` that **creates IAM roles**, without being
able to escalate its own privileges. This rests on two mechanisms (full rationale
inline in [`iam-ci.tf`](./iam-ci.tf)):

1. **Permissions boundary** (`tf-managed-boundary`) caps every CI-created role:
   effective perms = `intersection(attached policies, boundary)`. Even
   `AdministratorAccess` on a child role is clamped. The boundary is
   "admin minus a hardened deny-list" (no IAM users, no boundary tampering, no
   org/account actions, can't edit itself).
2. **A repo-scoped path** `/tf-managed/IntegratedDynamic/infrastructure/`. The CI
   grant only allows `iam:CreateRole` / `Attach*` / `Put*` **when the request
   stamps our boundary**, and only on ARNs under this path. `iam:PassRole` is
   likewise path-scoped. A global backstop Deny refuses to touch any role whose
   boundary isn't ours.

> ⚠️ **Contract for every root that creates roles:** each `aws_iam_role` the CI
> applies **must** set `permissions_boundary = <permissions_boundary_arn>` and
> `path = <managed_path>`, or the apply is rejected. With the `iam-role` module
> those are the `permissions_boundary` and `path` inputs. In CI, feed the path
> automatically:
>
> ```yaml
> env:
>   TF_VAR_role_path: /tf-managed/${{ github.repository }}/
> ```
>
> `${{ github.repository }}` resolves to `IntegratedDynamic/infrastructure`,
> matching the pin exactly. IAM paths are **case-sensitive**.

Verify the guardrails with the IAM policy simulator, e.g.:

```bash
ROLE=$(terraform -chdir=aws-github-oidc output -raw role_arn)
B=$(terraform -chdir=aws-github-oidc output -raw permissions_boundary_arn)
# CreateRole without our boundary -> explicitDeny
aws iam simulate-principal-policy --policy-source-arn "$ROLE" \
  --action-names iam:CreateRole \
  --resource-arns "arn:aws:iam::503577850357:role/tf-managed/IntegratedDynamic/infrastructure/x" \
  --query 'EvaluationResults[0].EvalDecision' --output text
```

## Credentials

- **AWS** provider reads creds from the **AWS SDK chain** — locally your
  `aws sso login` session / profile; in CI the role itself once assumed. Nothing
  hardcoded, no `*.auto.tfvars` secret needed (`nico.auto.tfvars` is a gitignored
  placeholder with no sensitive values).
- The **S3 state backend** authenticates the same way.

## Apply

```bash
mise run aws-github-oidc-plan    # terraform init && plan — review first
mise run aws-github-oidc-apply   # terraform apply (creates IAM resources)
```

> Never `terraform apply`/`destroy` here without explicit approval.

## Wiring CI (manual, post-apply)

The role ARN is known only **after** apply, and workflows reference it via a repo
variable (an ARN is a public identifier, not a secret). Set it once:

```bash
gh variable set AWS_GITHUB_ACTIONS_ROLE_ARN \
  --repo IntegratedDynamic/infrastructure \
  --body "$(terraform -chdir=aws-github-oidc output -raw role_arn)"
```

Workflows then assume the role with `aws-actions/configure-aws-credentials`:

```yaml
permissions:
  id-token: write   # mint the OIDC token
  contents: read

steps:
  - uses: aws-actions/configure-aws-credentials@<pinned-sha>
    with:
      role-to-assume: ${{ vars.AWS_GITHUB_ACTIONS_ROLE_ARN }}
      aws-region: eu-west-3
  - run: aws s3 ls s3://id-terraform-state20260612164136440800000001
```

No `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` secrets are required.

## Revocation

The role and provider live entirely in this root's state.

- **Revoke CI access** — delete the role (or detach the `tf-managed-ci` policy);
  any workflow assuming it then fails.
- **Revoke everything** — `terraform destroy` removes the role and the OIDC
  provider. Mind that the OIDC provider is account-wide; only destroy it if no
  other role depends on it.
