# terraform-ci

A standalone Terraform root that provisions the **Scaleway identity the Terraform
CI/CD pipeline uses to apply `cluster/scaleway`**. Its first consumers are the
workflows added in #29 (`terraform-apply.yml`, `terraform-destroy-manual.yml`,
`terraform-destroy-scheduled.yml`), which run `terraform apply`/`destroy` against
the Scaleway Kapsule cluster, node pool, VPC and the S3 state backend.

This is **not** under `cluster/` — it provisions no cluster. It's a CI-platform
concern, kept as its own root so its state and blast radius stay small.

## Why a dedicated identity (distinct from `github-ci/`)

`github-ci/` mints a read-only identity (`ObjectStorageReadOnly`) for the bucket
smoke test — too narrow to run Terraform against the cluster. Rather than widen
that identity, `terraform-ci/` is its **own** IAM application + policy + key +
state, so:

- Revoking the terraform-ci key has **no blast radius** on the read-only key, and
  vice versa.
- The two keys carry **distinct credential names** — see [Credential naming](#credential-naming).

## Why a static key and not OIDC

The ideal flow would be **keyless GitHub-OIDC → Scaleway** (GitHub mints a
short-lived OIDC token, Scaleway trades it for temporary credentials, no
long-lived secret). **This is not possible today**: Scaleway IAM is not an OIDC
relying party — the IAM API exposes only API keys, SSH keys, SAML SSO, SCIM and
an internal user-session JWT. The feature request for it is still open:

- https://feature-request.scaleway.com/posts/761/oidc-provider-for-external-ci-cd

So we use Scaleway's supported pattern — a dedicated, least-privilege **API
key** — and mitigate the long-lived-secret risk with least privilege and a
dedicated, independently-revocable identity. Revisit OIDC if/when Scaleway ships
it (see the link above).

## What it creates

- `scaleway_iam_application.terraform_ci` — the Terraform CI identity (name `terraform-ci`).
- `scaleway_iam_policy.terraform_ci` — least privilege for `cluster/scaleway`,
  all scoped to `var.project_id`:

  | Permission set | Why |
  |---|---|
  | `ObjectStorageReadWrite` | R/W the Object Storage Terraform state backend (`terraform-state-bucket/`) |
  | `KubernetesFullAccess` | `scaleway_k8s_cluster` + `scaleway_k8s_pool` |
  | `VPCFullAccess` | `scaleway_vpc_private_network` |

  The Kubernetes/Helm providers authenticate via the cluster kubeconfig and the
  Infisical provider via its own creds, so neither needs an IAM permission set.
  The `ObjectStorageReadWrite` set also covers `terraform plan`/`apply` reading
  and writing this root's own remote state.
- `scaleway_iam_api_key.terraform_ci` — the API key for that application, with
  `default_project_id` baked in. The org enforces an expiry on every key, so
  `time_rotating.api_key` drives `expires_at` (default 365 days,
  `var.api_key_rotation_days`) and rotates the key on the next apply after it
  lapses — see [Rotation / revocation](#rotation--revocation).
- `infisical_secret.tf_scw_access_key` / `infisical_secret.tf_scw_secret_key` —
  the key written into Infisical (env `staging`, folder `/ci` by default) as
  `TF_SCW_ACCESS_KEY` / `TF_SCW_SECRET_KEY`. The secret half is
  Terraform-`sensitive`; it's never printed or committed (state-only).

State lives at `terraform-ci/...` in the shared S3 bucket — independent from
`github-ci/` and `cluster/scaleway/`.

> **Note on the shared `/ci` Infisical folder:** both `github-ci/` and
> `terraform-ci/` declare an `infisical_secret_folder.ci` for the same `/ci`
> path. They keep separate state and write **different** secret names
> (`SCW_*` vs `TF_SCW_*`), so there's no key collision. If `github-ci/` has
> already created `/ci`, simply `terraform import` the existing folder into this
> root (or let the apply reconcile it) — the secrets are the real payload.

## Credential naming

Distinct names keep the two identities unambiguous wherever they're consumed:

| Identity | Permissions | GitHub secret names |
|---|---|---|
| `github-ci/` (read-only smoke test) | `ObjectStorageReadOnly` | `SCW_ACCESS_KEY` / `SCW_SECRET_KEY` |
| `terraform-ci/` (this root) | `ObjectStorageReadWrite` + `KubernetesFullAccess` + `VPCFullAccess` | `TF_SCW_ACCESS_KEY` / `TF_SCW_SECRET_KEY` |

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
mise run terraform-ci-plan    # terraform init && plan — review first
mise run terraform-ci-apply   # terraform apply (billable: creates an IAM key)
```

> Never `terraform apply`/`destroy` here without explicit approval.

After apply, the access key is an output and both halves are in Infisical.

## Wiring the GitHub secrets (manual)

Automating the Infisical → GitHub push is deferred (it'd mean adding a GitHub
token to this bootstrap). For now, set the two secrets by hand. Read the values
straight out of the Terraform state/output and Infisical — **don't paste them
into your shell history or echo them**.

The consuming workflows (#29) are split: `terraform-apply.yml` runs in the gated
`scaleway` GitHub **Environment**, but the **destroy** workflows are ungated and
read **repo-level** secrets. So set the pair in **both** scopes:

```bash
# 1) Environment-scoped (for terraform-apply.yml, gated on `scaleway`):
gh secret set TF_SCW_ACCESS_KEY \
  --repo IntegratedDynamic/infrastructure --env scaleway \
  --body "$(terraform -chdir=terraform-ci output -raw access_key)"

gh secret set TF_SCW_SECRET_KEY \
  --repo IntegratedDynamic/infrastructure --env scaleway \
  --body "$(terraform -chdir=terraform-ci state show -no-color scaleway_iam_api_key.terraform_ci \
            | awk '/secret_key/ {print $3; exit}' | tr -d '\"')"

# 2) Repo-level (for the ungated destroy workflows):
gh secret set TF_SCW_ACCESS_KEY \
  --repo IntegratedDynamic/infrastructure \
  --body "$(terraform -chdir=terraform-ci output -raw access_key)"

gh secret set TF_SCW_SECRET_KEY \
  --repo IntegratedDynamic/infrastructure \
  --body "$(terraform -chdir=terraform-ci state show -no-color scaleway_iam_api_key.terraform_ci \
            | awk '/secret_key/ {print $3; exit}' | tr -d '\"')"
```

(Or copy the secret from Infisical → `staging` → `/ci` → `TF_SCW_SECRET_KEY` and
pipe it into `gh secret set ... < /dev/stdin`.)

## Verify end to end

The smoke-test job in `.github/workflows/scaleway-auth-check.yml`
(`list-state-bucket-terraform-ci`) authenticates with `TF_SCW_ACCESS_KEY` /
`TF_SCW_SECRET_KEY` and lists the fr-par Object Storage buckets (where the
Terraform state backend lives) — confirming the `ObjectStorageReadWrite` grant
resolves. It triggers on any PR touching `terraform-ci/**` or the workflow
itself, so you can validate before merge.

So the validation order is: `apply` → `gh secret set` (above) → push the branch /
re-run the PR check. A green run means real authentication succeeded.

## Rotation / revocation

The API key lives entirely in this root's state.

- **Automatic** — `time_rotating.api_key` expires the key after
  `var.api_key_rotation_days` (default 365). Once that window lapses, the next
  `terraform apply` rolls the expiry forward, which (since `expires_at` is
  ForceNew) creates fresh key material.
- **On demand** — force it early with:

  ```bash
  terraform -chdir=terraform-ci apply -replace=scaleway_iam_api_key.terraform_ci
  ```

Either way the key material changes, so **re-run the `gh secret set` steps above**
afterwards in **both** scopes (the Infisical copies update automatically; the
GitHub secrets don't).

To kill access entirely, destroy the application (revokes the key) — but mind
that any workflow depending on it will start failing.
