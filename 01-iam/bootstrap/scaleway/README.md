# 01-iam/bootstrap/scaleway — Scaleway CI identity

A standalone Terraform root that provisions the **Scaleway identity GitHub
Actions uses to authenticate to Scaleway**. First real consumer: a smoke-test
workflow that lists Object Storage buckets; the Terraform CI/CD pipeline itself
is a separate, later concern.

This is **not** under `10-cluster/` — it provisions no cluster. It's a
`01-iam/bootstrap/` trust anchor (human-applied), kept as its own root so its
state and blast radius stay small.

## Why a static key and not OIDC

The ideal flow would be **keyless GitHub-OIDC → Scaleway** (GitHub mints a
short-lived OIDC token, Scaleway trades it for temporary credentials, no
long-lived secret). **This is not possible today**: Scaleway IAM is not an OIDC
relying party — the IAM API exposes only API keys, SSH keys, SAML SSO, SCIM and
an internal user-session JWT. The feature request for it is still open:

- https://feature-request.scaleway.com/posts/761/oidc-provider-for-external-ci-cd

So we use Scaleway's supported pattern — a dedicated, least-privilege **API
key** — and mitigate the long-lived-secret risk with:

- **Least privilege** — `ObjectStorageReadOnly`, scoped to a single project.
- **A dedicated, independently-revocable identity** — its own IAM application, so
  it can be rotated/revoked without touching anything else.

Revisit OIDC if/when Scaleway ships it (see the link above).

## What it creates

Via `module "ci_identity"` ([modules/scaleway-machine-identity](../../../modules/scaleway-machine-identity)):

- One `scaleway_iam_application` — the CI identity.
- Two `scaleway_iam_policy` objects on it: `cluster_management` (`VPCFullAccess`,
  `KubernetesFullAccess`, `PrivateNetworksFullAccess`, `IPAMReadOnly`, project-scoped —
  lets CI create/destroy the Kapsule cluster) and `backup_management` (Object
  Storage bucket/object management, project-scoped, plus `IAMApplicationManager`/
  `IAMPolicyManager`, org-scoped — lets CI provision the storage domain's buckets
  and their scoped workload identities in `03-storage/scaleway/`).
- One `scaleway_iam_api_key` for that application, with `default_project_id` baked
  in so `scw object bucket list` resolves the right scope without the workflow
  passing a project ID. The org enforces an expiry on every key, so
  `time_rotating` drives `expires_at` (default 365 days, `var.api_key_rotation_days`)
  and rotates the key on the next apply after it lapses — see
  [Rotation / revocation](#rotation--revocation).

Nothing is pushed to Infisical (retired — see repo root). The secret key stays
state-only; distribute it by hand (see below).

## Credentials

Same as the other roots:

- **Scaleway** provider reads creds + default region/project from the **scw CLI
  config** (`~/.config/scw/config.yaml`).
- The **S3 state backend** authenticates with AWS-style env vars derived from the
  scw config; `mise.toml`'s `[env]` block injects them automatically under mise.

## Apply

```bash
terraform -chdir=01-iam/bootstrap/scaleway init
terraform -chdir=01-iam/bootstrap/scaleway plan    # review first
terraform -chdir=01-iam/bootstrap/scaleway apply   # billable: creates an IAM key
```

> Never `terraform apply`/`destroy` here without explicit approval.

After apply, the access key is an output; the secret key is state-only.

## Wiring the GitHub secrets (manual)

There's no automated push (Infisical, which used to carry this, is retired) — set
the two repo secrets by hand. Read the values straight out of the Terraform
state/output — **don't paste them into your shell history or echo them**:

```bash
# SCW_ACCESS_KEY is a public identifier, exposed as a Terraform output:
gh secret set SCW_ACCESS_KEY \
  --repo IntegratedDynamic/infrastructure \
  --body "$(terraform -chdir=01-iam/bootstrap/scaleway output -raw access_key)"

# SCW_SECRET_KEY is sensitive — pipe it from the API key resource without printing:
gh secret set SCW_SECRET_KEY \
  --repo IntegratedDynamic/infrastructure \
  --body "$(terraform -chdir=01-iam/bootstrap/scaleway state show -no-color 'module.ci_identity.scaleway_iam_api_key.this' \
            | awk '/secret_key/ {print $3; exit}' | tr -d '\"')"
```

## Verify end to end

The smoke-test workflow (`.github/workflows/scaleway-auth-check.yml`) runs
`scw object bucket list region=fr-par` against the key. It triggers on any PR
that touches `01-iam/bootstrap/scaleway/**` or the workflow itself, so you can validate before
merge.

It needs two **repo variables** (public identifiers, not secrets — the scw CLI
wants them even for a project-scoped key). Set once:

```bash
gh variable set SCW_DEFAULT_ORGANIZATION_ID --repo IntegratedDynamic/infrastructure --body "<org-id>"
gh variable set SCW_DEFAULT_PROJECT_ID      --repo IntegratedDynamic/infrastructure --body "<project-id>"
```

So the validation order is: `apply` → `gh secret set` (above) → push the branch /
re-run the PR check. The job runs in the `scaleway` GitHub Environment (so its
secret usage is scoped — secrets can be set at repo or environment level; the
repo-level commands above work either way). It fails clearly if the secrets are
missing, so a green run means real authentication succeeded.

## Rotation / revocation

The API key lives entirely in this root's state.

- **Automatic** — `time_rotating.api_key` expires the key after
  `var.api_key_rotation_days` (default 365). Once that window lapses, the next
  `terraform apply` rolls the expiry forward, which (since `expires_at` is
  ForceNew) creates fresh key material.
- **On demand** — force it early with:

  ```bash
  terraform -chdir=01-iam/bootstrap/scaleway apply -replace='module.ci_identity.scaleway_iam_api_key.this'
  ```

Either way the key material changes, so **re-run the `gh secret set` steps above**
afterwards.

To kill access entirely, destroy the application (revokes the key) — but mind
that any workflow depending on it will start failing.
