# 05-secrets/openbao/managed — OpenBao's internal configuration as code

Reconciles Terraform with OpenBao's **actual, already-running** state — not
just structure (mounts, auth methods, policies) but the secret content
living inside too. None of this lived in git before — it was applied by hand
against the live cluster (see the gitops repo's `PLAN-secrets-sync-github.md`
for the manual commands this replaces) and only survived via the raft
snapshots restored at boot by `apps/openbao-init/`.

This is not a fresh bootstrap: every resource here was **imported**, not
created, so that after the first `terraform apply` OpenBao ended up in
exactly the state it was already in — as if it had been built by Terraform
from the start. See "Reconciling on a fresh checkout" below.

## Why its own root, separate from `05-secrets/openbao/bootstrap`

`bootstrap/openbao` created the `terraform` AppRole itself — that needed a
human admin credential (OIDC), the same trust-anchor pattern as
`01-iam/bootstrap/*`. This root is what that AppRole is *for*: it
authenticates as the AppRole (machine identity), not as a human, and its
policy covers everything OpenBao's own config owns the lifecycle of —
structure (mounts, auth methods, roles, policies) **and** secret content
(`kv/data|metadata/apps/*`, `create`/`read`/`update`, deliberately no
`delete` — this identity creates/reconciles secret content, it doesn't
destroy it).

## What it manages

**Structure:**
- `vault_mount.kv` — the `kv/` v2 engine holding all application secret data.
- `vault_auth_backend.kubernetes` + `vault_kubernetes_auth_backend_config` —
  in-cluster ServiceAccount login (`kubernetes_host = https://kubernetes.default.svc`).
- `vault_kubernetes_auth_backend_role.snapshot` / `.external_secrets` — bound
  to the raft snapshot agent and ESO's `ClusterSecretStore` respectively.
- `vault_jwt_auth_backend.oidc` + `vault_jwt_auth_backend_role.admin` — human
  login via Dex (gitops repo `platform/scaleway/dex.yml`,
  `staticClients.openbao`), gated on the `IntegratedDynamic:Admin` GitHub
  group.
- `vault_policy.eso_read` / `.snapshot` / `.admin` — the policies the roles
  above bind to.

**Secret content** (`kv/apps/*`), each a `vault_kv_secret_v2` using the
write-only `data_json_wo`/`data_json_wo_version` pair — the provider never
reads secret values back from Vault to diff them (deliberate, avoids leaking
plaintext into the state file), so `data_json_wo_version` is the only signal
that triggers a rewrite; bump it to rotate:
- `dex_credentials` (`apps/dex/credentials`) — Dex's client secrets for
  argocd/envoy/grafana/openbao are **Terraform-generated**
  (`random_password.*`, arbitrary shared secrets, nothing external
  constrains them) plus `github-client-id`/`github-client-secret` (Dex's
  GitHub *connector* credentials — external, from GitHub's own OAuth App,
  supplied via `var.dex_github_connector`).
- `grafana_admin` (`apps/grafana/admin`) — `admin-password` is
  Terraform-generated (`random_password.grafana_admin_password`);
  `admin-user` is the hardcoded literal `"admin"`.
- `external_dns_scaleway_dns_credentials` (`apps/external-dns/scaleway-dns-credentials`)
  — `SCW_ACCESS_KEY`/`SCW_SECRET_KEY` come straight from
  `data.terraform_remote_state.dns_scaleway` (infra's own `04-dns/scaleway`
  IAM root), not a hand-copied variable — closes the "seed pending, no
  automated push yet" gap that root's own `outputs.tf` used to flag.
- `secrets_sync_github_eso_private_key` (`apps/secrets-sync/github/eso-github-app-private-key`)
  — the GitHub App private key, external (downloaded from GitHub), supplied
  via `var.secrets_sync_github_eso_private_key`.
- `secrets_sync_github_global` / `secrets_sync_github_repo[...]` /
  `secrets_sync_github_repo_env[...]` (`apps/secrets-sync/github/*`) — see
  `var.secrets_sync_github` below.
- `velero_scaleway_s3_credentials` (`apps/velero/scaleway-s3-credentials`) —
  `SCW_ACCESS_KEY`/`SCW_SECRET_KEY` come from
  `data.terraform_remote_state.backup_scaleway` (infra's own `03-backup/scaleway`
  root), but a SEPARATE IAM key and bucket from OpenBao's own snapshot agent —
  sharing OpenBao's bucket broke its own `s3cmd`-based retention cleanup
  (confirmed live 2026-07-28), so Velero gets `scaleway_object_bucket.velero`
  + `scaleway_iam_application.velero` of its own.

Deliberately **not** managed: `default` and `root` (OpenBao built-ins), and
the `approle`/`terraform` auth backend/policy/role (owned by
`05-secrets/openbao/bootstrap` — importing them here too would split-brain
two Terraform states over the same objects).

## `var.secrets_sync_github`'s shape

Scoped explicitly by org/repo/repo+environment instead of one flat KV path
string per target, so a GitHub repo/environment rename is a map-key rename
here, not a hunt through hardcoded path segments:

```hcl
secrets_sync_github = {
  global = { TEST_ORGA = "..." }              # -> kv/apps/secrets-sync/github/global
  repos = {
    infrastructure = {
      secrets = { TEST_REPO = "..." }         # -> kv/apps/secrets-sync/github/infrastructure
      environments = {
        scaleway = { TEST_SCALEWAY = "..." }  # -> kv/apps/secrets-sync/github/infrastructure-scaleway
        # SCW_ACCESS_KEY/SCW_SECRET_KEY are merged in from
        # data.terraform_remote_state.dns_scaleway, not set here.
      }
    }
  }
}
```

This mirrors the gitops repo's `apps/secrets-sync/values.yaml` `targets`
shape — but that chart's `targets[].repository`/`.environment` still need
updating too on a rename. Two independent systems kept in sync by
convention, not automation.

## Credentials

- **AppRole** (`var.approle_role_id` / `var.approle_secret_id`): from
  `05-secrets/openbao/bootstrap`'s outputs —

  ```bash
  terraform -chdir=../../bootstrap/openbao output -raw role_id
  terraform -chdir=../../bootstrap/openbao output -raw secret_id
  ```

- **`var.dex_github_connector`**, **`var.secrets_sync_github_eso_private_key`**:
  external credentials this identity's policy can't read back on its own
  (no `kv/data/*` access needed since these are just supplied, not
  round-tripped) — fetch current values from OpenBao directly (an admin
  OIDC session can read `kv/data/apps/dex/credentials` etc.) and add them to
  a gitignored `local.auto.tfvars` (matches `*.auto.tfvars` in the repo
  `.gitignore`, same convention as `02-cluster/scaleway/local.auto.tfvars`).
  Never paste secret values into shell history or commit them.

- Everything else (`random_password.*`) is Terraform-generated — no
  variable needed.

## Reconciling on a fresh checkout

Resources already existing in OpenBao need one `terraform import` each, once,
to attach Terraform's state to them without recreating anything — see git
history for the exact import commands used (mount, auth backends/roles,
policies, then each `vault_kv_secret_v2` via `<mount>/data/<name>` as the
import ID, e.g. `kv/data/apps/dex/credentials`).

```bash
terraform -chdir=05-secrets/openbao/managed init
terraform -chdir=05-secrets/openbao/managed workspace select -or-create 05-secrets-openbao-secrets
terraform -chdir=05-secrets/openbao/managed plan
```

A clean plan on the structure resources (zero changes) confirms the code
matches reality. The `vault_kv_secret_v2` resources will always show
`data_json_wo`-related churn only when `data_json_wo_version` changes —
otherwise they stay silent even though their actual content is never
diffed (by design, see above).

## Apply

```bash
terraform -chdir=05-secrets/openbao/managed plan
terraform -chdir=05-secrets/openbao/managed apply
```

> Never `terraform apply`/`destroy` here without explicit approval — this
> backs live authentication paths (ESO, the snapshot agent, human OIDC
> login) and live secret content (Dex/ArgoCD/Grafana client secrets,
> Grafana's admin password, GitHub Actions secrets). A bad apply can lock
> out access to the cluster's own secrets.
>
> Rotating any Terraform-generated secret (bump the corresponding
> `random_password`'s underlying trigger, or `-replace` it, **and** bump
> the owning `vault_kv_secret_v2`'s `data_json_wo_version` in the same
> change) takes effect live immediately, but downstream consumers
> (Dex/ArgoCD/Grafana pods reading via `secretKeyRef` env vars) do **not**
> hot-reload — force their `ExternalSecret`s to refresh (e.g. annotate them
> to trigger reconciliation) and roll out the affected deployments right
> after, or there's a window where OIDC login fails with
> `invalid_client`/`"Invalid client credentials."` on the stale side.
