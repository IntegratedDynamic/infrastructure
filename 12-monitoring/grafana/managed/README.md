# 12-monitoring/grafana/managed — Grafana configuration, as code

Grafana's actual declarative configuration, reconciled by authenticating
directly as Grafana's **admin** (basic auth, password owned by
`11-secrets/openbao/managed`). This is where Grafana-as-code lives:
service accounts, data sources, dashboards, and later folders, alerting,
OIDC config, etc. — same role `11-secrets/openbao/managed` plays for
OpenBao.

There is no `12-monitoring/grafana/bootstrap` root: it only ever minted a
`terraform` service-account token for this root's `grafana` provider, and
that token could stop authenticating after a Velero restore while still
showing valid in Grafana's own metadata (infra#82 mode 1). Authenticating
as the admin password OpenBao already regenerates-and-repushes on every
restore removes that failure class outright, with no chicken-and-egg
(Grafana's admin password is already Terraform state, unlike OpenBao's
`root_token`).

## What it creates

- `grafana_service_account.mcp_claude_code` — `role = "Editor"`, the
  identity [`github.com/grafana/mcp-grafana`](https://github.com/grafana/mcp-grafana)
  (the Grafana MCP server) authenticates as. Editor per that project's own
  documented recommendation — enough for its typical toolset (dashboards,
  datasources, alerts) without full Admin.
- `grafana_service_account_token.mcp_claude_code` — the token, generated
  once at apply time. `seconds_to_live` from
  `var.mcp_service_account_token_ttl_days` (default `0` — never expires;
  set a positive value to opt into rotation). Exposed only as a `sensitive`
  OpenTofu output (`mcp_service_account_token`) — the sole consumer is a
  human on their own machine registering the MCP server. Not written to
  OpenBao / synced into the cluster: state is always current post-apply,
  and a second copy is just something else to keep fresh (see this root's
  `outputs.tf` for the 2026-08-14 postmortem that dropped the OpenBao
  write).

## A note on dynamic secrets

A community Vault plugin exists for this
([`Boostport/vault-plugin-secrets-grafana`](https://github.com/Boostport/vault-plugin-secrets-grafana)) —
it would let OpenBao mint short-lived, auto-revoked Grafana tokens on demand
instead of this root's static, Terraform-rotated one. Deliberately not
adopted here: it still needs a standing Grafana admin credential as its own
backing secret, and registering a third-party (non-official) plugin binary
is a real change to OpenBao's own deployment (gitops repo), not just a
Terraform resource — worth a dedicated follow-up if/when this grows beyond
one personal-use token.

## Restore-adopt (infra#82)

`main.tf` (re)creates the `Prometheus`/`Loki`/`Tempo` data sources and the
default dashboards that were lost when Grafana split out of
`kube-prometheus-stack`, plus the MCP service account. After a Velero PVC
restore, Grafana can already carry any of these under ids this root's own
state doesn't track — a plain `apply` then `POST`s a name that exists and
wedges on a 400/409 (the provider has no adopt-if-present behaviour). Until
issue #101 a gitops CronWorkflow preflight patched this with `state rm` +
`import`; that hook is gone. Two mechanisms replace it, both in `main.tf`,
neither able to oscillate in the Crossplane reconcile loop:

1. **Pinned `uid` on every `grafana_data_source`** (`prometheus` / `loki` /
   `tempo`) — the [provider's own documented pattern](https://registry.terraform.io/providers/grafana/grafana/latest/docs/resources/data_source)
   (`uid` is a first-class field and the import id). A **state-intact**
   restore then just refreshes cleanly — every snapshot carries the
   datasource under the id state expects. Dashboards need no pin: they use
   `overwrite = true` (upsert by embedded uid).

2. **Config-driven `import` blocks**, gated on two admin-authed
   `data.http` probes (`api/serviceaccounts/search`, `api/datasources`).
   When this root's **state is fresh but Grafana already carries** the SA
   or a datasource (state rebuilt, or a `state rm`), the `import` adopts it
   instead of `POST`ing. `import` is idempotent — a no-op once the resource
   is in state — and carries no `replace_triggered_by`. On a truly fresh
   Grafana the probes return nothing and the resources create normally.

So every resource this root manages is restore-safe: state-intact restore →
clean refresh (uid pins); state lost, resource live → adopt (`import`);
both fresh → create. No human `tofu state rm` in the loop.

`hashicorp/http` returns a non-2xx (401, 404, 5xx) as *data*, so an
auth/permission problem is observable in the probe result rather than a
plan failure. A hard *transport* failure (Grafana Service down, DNS) does
fail the plan — the Workspace then just isn't `READY` and retries on
provider-opentofu's backoff, and the `crossplane-apps` tier's
`wait_grafana_healthy` gate keeps that from happening on the very first
reconcile.

- `uid` is `ForceNew` on `grafana_data_source`, so the very first apply of
  the uid pin replaced the auto-uid data sources once — harmless (dashboards
  resolve via the `$datasource` template var).
- The SA **token** (`grafana_service_account_token.mcp_claude_code`) has no
  adopt path — its secret isn't retrievable — so a state-loss restore
  recreates it (new `.key`, re-fetch via `tofu output`); the old token is
  left orphaned in Grafana. Low stakes for a personal MCP token.

## Credentials

- **`grafana` provider**: authenticates as Grafana's **admin** via basic
  auth (`"admin:${var.grafana_admin_password}"`). The password —
  `11-secrets/openbao/managed`'s `random_password.grafana_admin_password`,
  backing `kv/apps/grafana/admin` — reaches this root as the env var
  **`TF_VAR_grafana_admin_password`**, not a cross-root state read:
  - **in-cluster**: the Crossplane Workspace maps it from the ESO-synced
    Secret `crossplane-grafana-admin` (gitops
    `services/platform/crossplane/config`, same `openbao` ClusterSecretStore
    every other ExternalSecret uses).
  - **locally**: `export TF_VAR_grafana_admin_password=$(bao kv get -field=admin-password kv/apps/grafana/admin)`.

  `var.grafana_url` defaults to Grafana's internal Service address (via the
  WireGuard tunnel, infrastructure#81); the in-cluster Workspace overrides
  it with `TF_VAR_grafana_url`.
- **S3 state backend**: same AWS-style env vars as every other root (via
  `mise.toml`'s `[env]` block).

## Apply

```bash
export TF_VAR_grafana_admin_password=$(bao kv get -field=admin-password kv/apps/grafana/admin)  # bring the WireGuard tunnel up first
tofu -chdir=12-monitoring/grafana/managed init
tofu -chdir=12-monitoring/grafana/managed workspace select -or-create 12-monitoring-grafana-managed-dev
tofu -chdir=12-monitoring/grafana/managed plan  -var-file=env/12-monitoring-grafana-managed-dev.tfvars
tofu -chdir=12-monitoring/grafana/managed apply -var-file=env/12-monitoring-grafana-managed-dev.tfvars
```

> Never `tofu apply`/`destroy` here **by hand** without explicit approval.

In-cluster this root is reconciled continuously by Crossplane
(`opentofu.upbound.io/Workspace` `grafana-managed`, gitops repo's
`services/platform/crossplane`) against `main` — issue #101, replacing the
Argo Workflows CronWorkflow. `TF_VAR_grafana_admin_password` /
`TF_VAR_grafana_url` come from that chart's env wiring (the
`crossplane-grafana-admin` ESO Secret + a literal). No cross-root state
read and no explicit ordering primitive — Grafana just has to be reachable,
which the `crossplane-apps` tier's `wait_grafana_healthy` gate ensures
before the Workspace is even created. `deletionPolicy: Orphan` +
`managementPolicies` without `Delete` mean Crossplane only ever
creates/updates.

## Fetching the MCP token

```bash
tofu -chdir=12-monitoring/grafana/managed output -raw mcp_service_account_token
```

Then register the MCP server (default `local` scope — not committed to git):

```bash
claude mcp add-json "grafana" '{"command":"uvx","args":["mcp-grafana"],"env":{"GRAFANA_URL":"https://grafana.scalepack.fr/","GRAFANA_SERVICE_ACCOUNT_TOKEN":"<token>"}}'
```

## Rotation / revocation

- **Token** — force early rotation with:

  ```bash
  tofu -chdir=12-monitoring/grafana/managed apply -replace=grafana_service_account_token.mcp_claude_code -var-file=env/12-monitoring-grafana-managed-dev.tfvars
  ```

  The new `.key` flows through automatically — re-fetch it with
  `tofu output -raw mcp_service_account_token` and re-register the MCP
  server; the old one stops working immediately.
- **Full revocation** — destroy `grafana_service_account.mcp_claude_code`.
