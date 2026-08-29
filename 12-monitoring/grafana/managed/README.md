# 12-monitoring/grafana/managed — Grafana configuration, as code

Grafana's actual declarative configuration, reconciled via the `terraform`
service account `12-monitoring/grafana/bootstrap` mints. Today that's just
one thing (the MCP server's own service account) — this is where future
Grafana-as-code lives: dashboards, folders, alerting, OIDC config, etc.,
same role `11-secrets/openbao/managed` plays for OpenBao.

## What it creates

- `grafana_service_account.mcp_claude_code` — `role = "Editor"`, the
  identity [`github.com/grafana/mcp-grafana`](https://github.com/grafana/mcp-grafana)
  (the Grafana MCP server) authenticates as. Editor per that project's own
  documented recommendation — enough for its typical toolset (dashboards,
  datasources, alerts) without full Admin.
- `grafana_service_account_token.mcp_claude_code` — the token, generated
  once at apply time. `seconds_to_live` from
  `var.mcp_service_account_token_ttl_days` (default `0` — never expires;
  set a positive value to opt into rotation).
- `vault_kv_secret_v2.grafana_mcp_token` — writes the token to
  `kv/apps/monitoring/grafana-mcp-token`. **Not** synced into the cluster by
  anything (no ESO ExternalSecret reads this) — the only consumer is a
  human (fetching it directly to configure the MCP server locally), same
  rationale as `11-secrets/openbao/managed`'s `apps/wireguard/confs`. ESO
  wouldn't help here anyway: its job is syncing into Kubernetes Secrets, and
  the actual consumer is a local `claude mcp` process, not a cluster
  workload.

## A note on dynamic secrets

A community Vault plugin exists for this
([`Boostport/vault-plugin-secrets-grafana`](https://github.com/Boostport/vault-plugin-secrets-grafana)) —
it would let OpenBao mint short-lived, auto-revoked Grafana tokens on demand
instead of this root's static, Terraform-rotated one. Deliberately not
adopted here: it still needs this same bootstrap Admin service account as
its own backing credential, and registering a third-party (non-official)
plugin binary is a real change to OpenBao's own deployment (gitops repo),
not just a Terraform resource — worth a dedicated follow-up if/when this
grows beyond one personal-use token.

## Self-heal (infra#82)

Beyond the MCP service account, `main.tf` also (re)creates the
`Prometheus`/`Loki`/`Tempo` data sources and the default dashboards that
were lost when Grafana split out of `kube-prometheus-stack`.

infra#82 mode 2 (first hit 2026-08-23): after a Velero PVC restore, Grafana
served a data source under a different random `uid` than the one in state,
so `apply` tried a plain `POST /datasources` for a name that already
existed and wedged on a 409. Until issue #101 a gitops CronWorkflow
preflight worked around this with `state rm` + `import`. That's gone now;
instead each `grafana_data_source` **pins `uid`** to a stable literal
(`prometheus` / `loki` / `tempo`), so every snapshot carries the
deterministic uid and any restore yields the one state expects.

- `uid` is `ForceNew`, so the first apply of this change replaces the
  auto-uid data sources once — harmless (dashboards resolve via the
  `$datasource` template var, not a hardcoded uid).
- Residual: a restore from a snapshot **older** than the uid-pin change
  still lands a random uid. One-off fix:
  `tofu state rm grafana_data_source.<name>` then re-apply. Self-limiting —
  pre-pin snapshots age out of Velero retention.

## Credentials

- **`grafana` provider**: authenticates as the `terraform` service account
  from `12-monitoring/grafana/bootstrap`, read via
  `data.terraform_remote_state` — see `version.tf`. Defaults to Grafana's
  internal Service address, same address/tunnel rationale as that root's
  own `version.tf` (infrastructure#81).
- **`vault` provider**: reuses the same `terraform` AppRole
  `11-secrets/openbao/managed` itself authenticates as (its policy already
  grants `kv/data|metadata/apps/*` broadly, so writing a new path here needs
  no OpenBao-side policy change) — see that root's `version.tf` for the
  address/split-DNS rationale.
- **S3 state backend**: same AWS-style env vars as every other root (via
  `mise.toml`'s `[env]` block).

## Apply

```bash
tofu -chdir=12-monitoring/grafana/managed init
tofu -chdir=12-monitoring/grafana/managed workspace select -or-create 12-monitoring-grafana-managed-dev
tofu -chdir=12-monitoring/grafana/managed plan  -var-file=env/12-monitoring-grafana-managed-dev.tfvars
tofu -chdir=12-monitoring/grafana/managed apply -var-file=env/12-monitoring-grafana-managed-dev.tfvars
```

> Never `tofu apply`/`destroy` here **by hand** without explicit approval.

In-cluster this root is reconciled continuously by Crossplane
(`opentofu.upbound.io/Workspace` `grafana-managed`, gitops repo's
`services/platform/crossplane`) against `main` — issue #101, replacing the
Argo Workflows CronWorkflow. It reads `grafana/bootstrap`'s
`service_account_token` via `terraform_remote_state`, so Crossplane's own
backoff is what sequences it after `grafana-bootstrap` (no explicit
ordering primitive). `deletionPolicy: Orphan` + `managementPolicies`
without `Delete` mean Crossplane only ever creates/updates.

## Fetching the MCP token

```bash
bao login -method=oidc   # your own OIDC admin session
bao kv get -field=token kv/apps/monitoring/grafana-mcp-token
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

  Bumps `data_json_wo_version` isn't needed here since the resource itself
  is replaced (new `.key` value flows through automatically) — but re-fetch
  the token from OpenBao afterward and re-register the MCP server, the old
  one stops working immediately.
- **Full revocation** — destroy `grafana_service_account.mcp_claude_code`.
