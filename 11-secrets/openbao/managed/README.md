# 11-secrets/openbao/managed — OpenBao's internal configuration as code

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

## Why its own root, separate from `11-secrets/openbao/bootstrap`

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

**Secret content** (`kv/apps/*`), each a `vault_kv_secret_v2` using plain
`data_json` — not the write-only `data_json_wo`/`data_json_wo_version` pair
this root used until 2026-08-20 (infra issue #73): write-only never reads
secret values back from Vault to diff them, so every content change also
needed a manual version bump, and a forgotten one meant `apply` reported "no
changes" while live OpenBao silently drifted from state (hit for real twice
— see the grafana_admin/wireguard_peers history in `main.tf`). Plaintext
ends up in state either way, since every value here already originates from
state (a `random_password.result`, a var, or a `terraform_remote_state`
output), so `data_json` costs nothing extra and buys real drift detection:
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
  `data.terraform_remote_state.dns_scaleway` (infra's own `01-iam/workload/scaleway`
  IAM root), not a hand-copied variable — closes the "seed pending, no
  automated push yet" gap that root's own `outputs.tf` used to flag.
- `secrets_sync_github_eso_private_key` (`apps/secrets-sync/github/eso-github-app-private-key`)
  — the GitHub App private key, external (downloaded from GitHub), supplied
  via `var.secrets_sync_github_eso_private_key`.
- `secrets_sync_github_global` / `secrets_sync_github_repo[...]` /
  `secrets_sync_github_repo_env[...]` (`apps/secrets-sync/github/*`) — see
  `var.secrets_sync_github` below.
- `wireguard_server_key` (`apps/wireguard/server-key`) — the WireGuard
  tunnel server's own key, sourced from `04-vpn/wireguard`'s
  `server_private_key` output (external to this provider — that root only
  generates keys locally, it doesn't write to OpenBao itself). Read back out
  by the gitops repo's `services/platform/wireguard/init` (ExternalSecret,
  same pattern as every other app's `init` chart) — its own object, since
  nothing else ever reads it.
- `secrets_sync_github_infrastructure_scaleway`'s `WG_CI_PRIVATE_KEY` field
  (below) — CI's own WireGuard peer key, sourced from `04-vpn/wireguard`'s
  `peer_private_keys["ci-github-actions"]` output, merged in alongside
  `SCW_ACCESS_KEY`/`SCW_SECRET_KEY` rather than a separate KV object: it
  needs to ride the *existing* `secrets-sync` pipeline out to a GitHub
  Actions secret, which reads from that one object, not a new one nothing
  would push. See `04-vpn/wireguard/README.md` for the full hand-off.
- `velero_scaleway_s3_credentials` (`apps/velero/scaleway-s3-credentials`) —
  `SCW_ACCESS_KEY`/`SCW_SECRET_KEY` come from
  `data.terraform_remote_state.backup_scaleway` (infra's own `03-storage/scaleway`
  root), but a SEPARATE IAM key and bucket from OpenBao's own snapshot agent —
  sharing OpenBao's bucket broke its own `s3cmd`-based retention cleanup
  (confirmed live 2026-07-28), so Velero gets `scaleway_object_bucket.velero`
  + `scaleway_iam_application.velero` of its own.
- `argo_workflows_scaleway_state_credentials`
  (`apps/argo-workflows/scaleway-state-credentials`) — `SCW_ACCESS_KEY`/
  `SCW_SECRET_KEY` for the gitops repo's Argo Workflows CronWorkflow (runs
  `terraform apply` on this very root, hourly, from inside the cluster —
  see that chart's own README for why). A dedicated workload identity
  (`01-iam/workload/scaleway`'s `argo-workflows-state`,
  `data.terraform_remote_state.dns_scaleway`), not a reused state-bucket
  identity — this credential is landed on the cluster, unlike every other
  cross-root read in this file, so it gets its own identity like any other
  in-cluster workload.
- `argo_workflows_openbao_managed_tfvars`
  (`apps/argo-workflows/openbao-managed-tfvars`) — a duplicate, JSON-encoded
  copy of `var.dex_github_connector` /
  `var.secrets_sync_github_eso_private_key` / `var.secrets_sync_github`, so
  the CronWorkflow's own unattended `terraform apply` of THIS root can
  satisfy those three required variables too (same admin-supplied value,
  written to a second KV path in the same apply — not a read-back of the
  "real" objects those variables also feed; see `main.tf`'s comment on this
  resource for why that distinction matters).

Deliberately **not** managed: `default` and `root` (OpenBao built-ins), and
the `approle`/`terraform` auth backend/policy/role (owned by
`11-secrets/openbao/bootstrap` — importing them here too would split-brain
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
        # data.terraform_remote_state.dns_scaleway, WG_CI_PRIVATE_KEY from
        # var.wireguard_ci_private_key — none of the three set here.
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
  `11-secrets/openbao/bootstrap`'s outputs —

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
  `.gitignore`, same convention as `10-cluster/scaleway/local.auto.tfvars`).
  Never paste secret values into shell history or commit them.
- **`var.wireguard_server_private_key`**, **`var.wireguard_ci_private_key`**:
  from `04-vpn/wireguard`'s outputs —

  ```bash
  terraform -chdir=../../../04-vpn/wireguard output -raw server_private_key
  terraform -chdir=../../../04-vpn/wireguard output -json peer_private_keys | jq -r '."ci-github-actions"'
  ```

  Same `local.auto.tfvars` as above.

- Everything else (`random_password.*`) is Terraform-generated — no
  variable needed.

## Reconciling on a fresh checkout

Resources already existing in OpenBao need one `terraform import` each, once,
to attach Terraform's state to them without recreating anything — see git
history for the exact import commands used (mount, auth backends/roles,
policies, then each `vault_kv_secret_v2` via `<mount>/data/<name>` as the
import ID, e.g. `kv/data/apps/dex/credentials`).

```bash
terraform -chdir=11-secrets/openbao/managed init
terraform -chdir=11-secrets/openbao/managed workspace select -or-create 11-secrets-openbao-managed-dev
terraform -chdir=11-secrets/openbao/managed plan
```

A clean plan (zero changes across the board, including the `vault_kv_secret_v2`
resources) confirms the code matches reality — `data_json` diffs actual
content now, so a clean plan is a real guarantee, not just silence born of
write-only never looking.

## Apply

```bash
terraform -chdir=11-secrets/openbao/managed plan
terraform -chdir=11-secrets/openbao/managed apply
```

> Never `terraform apply`/`destroy` here without explicit approval — this
> backs live authentication paths (ESO, the snapshot agent, human OIDC
> login) and live secret content (Dex/ArgoCD/Grafana client secrets,
> Grafana's admin password, GitHub Actions secrets). A bad apply can lock
> out access to the cluster's own secrets.
>
> Rotating any Terraform-generated secret (bump the corresponding
> `random_password`'s underlying trigger, or `-replace` it — `data_json`
> picks up the new value on the next apply, no separate version bump
> needed) takes effect live immediately, but downstream consumers
> (Dex/ArgoCD/Grafana pods reading via `secretKeyRef` env vars) do **not**
> hot-reload — force their `ExternalSecret`s to refresh (e.g. annotate them
> to trigger reconciliation) and roll out the affected deployments right
> after, or there's a window where OIDC login fails with
> `invalid_client`/`"Invalid client credentials."` on the stale side.
