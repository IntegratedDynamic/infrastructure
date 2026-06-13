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

## What it creates

- `aws_iam_openid_connect_provider.github_actions` — the GitHub Actions OIDC
  provider (`https://token.actions.githubusercontent.com`, audience
  `sts.amazonaws.com`). **One per AWS account** — if one already exists in the
  account, import it rather than creating a duplicate.
- `aws_iam_role.github_actions` (`github-actions-terraform`) — the role CI
  assumes. Its **trust policy** is scoped to exactly this repo
  (`repo:IntegratedDynamic/infrastructure:*`) with audience `sts.amazonaws.com`,
  so only workflows in this repo can assume it.
- `aws_iam_role_policy.github_actions_s3` (`terraform-state-s3`) — least
  privilege on exactly the state bucket: `s3:ListBucket` +
  `s3:GetBucketVersioning` on the bucket, and `s3:GetObject` / `s3:PutObject` /
  `s3:DeleteObject` on its objects (the S3-native locking the backend uses with
  `use_lockfile = true` rides on object R/W, so no DynamoDB table is needed).

`role_arn` is exposed as a Terraform output — it's a public identifier, not a
secret.

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

- **Revoke CI access** — delete the role (or tighten/detach the inline policy);
  any workflow assuming it then fails.
- **Revoke everything** — `terraform destroy` removes the role and the OIDC
  provider. Mind that the OIDC provider is account-wide; only destroy it if no
  other role depends on it.
