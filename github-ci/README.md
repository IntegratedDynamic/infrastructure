# github-ci

A standalone Terraform root that provisions the **Scaleway identity GitHub
Actions uses to authenticate to Scaleway**. First real consumer: a smoke-test
workflow that lists Object Storage buckets; the Terraform CI/CD pipeline itself
is a separate, later concern.

This is **not** under `cluster/` — it provisions no cluster. It's a CI-platform
concern, kept as its own root so its state and blast radius stay small.

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

- `scaleway_iam_application.github_ci` — the CI identity.
- `scaleway_iam_policy.github_ci` — `permission_set_names = ["ObjectStorageReadOnly"]`,
  scoped to `var.project_id` (and **no** broader set).
- `scaleway_iam_api_key.github_ci` — the API key for that application, with
  `default_project_id` baked in so `scw object bucket list` resolves the right
  scope without the workflow passing a project ID. The org enforces an expiry on
  every key, so `time_rotating.api_key` drives `expires_at` (default 365 days,
  `var.api_key_rotation_days`) and rotates the key on the next apply after it
  lapses — see [Rotation / revocation](#rotation--revocation).
- `infisical_secret.scw_access_key` / `infisical_secret.scw_secret_key` — the key
  written into Infisical (env `staging`, folder `/ci` by default). The secret half
  is Terraform-`sensitive`; it's never printed or committed (state-only, per the
  repo's bootstrap model).

## Credentials

Same as the other roots:

- **Scaleway** provider reads creds + default region/project from the **scw CLI
  config** (`~/.config/scw/config.yaml`).
- **Infisical** provider authenticates via a **universal-auth machine identity**;
  its `client_id` / `client_secret` come from `*.auto.tfvars` (per-developer,
  gitignored — see `nico.auto.tfvars`).
- The **S3 state backend** authenticates with AWS-style env vars derived from the
  scw config; `mise.toml`'s `[env]` block injects them automatically under mise.

## Apply

```bash
mise run github-ci-plan    # terraform init && plan — review first
mise run github-ci-apply   # terraform apply (billable: creates an IAM key)
```

> Never `terraform apply`/`destroy` here without explicit approval.

After apply, the access key is an output and both halves are in Infisical.

## Wiring the GitHub secrets (manual)

Automating the Infisical → GitHub push is deferred (it'd mean adding a GitHub
token to this bootstrap). For now, set the two repo secrets by hand. Read the
values straight out of the Terraform state/output and Infisical — **don't paste
them into your shell history or echo them**:

```bash
# SCW_ACCESS_KEY is a public identifier, exposed as a Terraform output:
gh secret set SCW_ACCESS_KEY \
  --repo IntegratedDynamic/infrastructure \
  --body "$(terraform -chdir=github-ci output -raw access_key)"

# SCW_SECRET_KEY is sensitive — pipe it from the API key resource without printing:
gh secret set SCW_SECRET_KEY \
  --repo IntegratedDynamic/infrastructure \
  --body "$(terraform -chdir=github-ci state show -no-color scaleway_iam_api_key.github_ci \
            | awk '/secret_key/ {print $3; exit}' | tr -d '\"')"
```

(Or copy the secret from Infisical → `staging` → `/ci` → `SCW_SECRET_KEY` and
`gh secret set SCW_SECRET_KEY --repo IntegratedDynamic/infrastructure` reading
from stdin.)

## Verify end to end

The smoke-test workflow (`.github/workflows/scaleway-auth-check.yml`) runs
`scw object bucket list region=fr-par` against the key. It triggers on any PR
that touches `github-ci/**` or the workflow itself, so you can validate before
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
  terraform -chdir=github-ci apply -replace=scaleway_iam_api_key.github_ci
  ```

Either way the key material changes, so **re-run the `gh secret set` steps above**
afterwards (the Infisical copies update automatically; the GitHub secrets don't).

To kill access entirely, destroy the application (revokes the key) — but mind
that any workflow depending on it will start failing.
