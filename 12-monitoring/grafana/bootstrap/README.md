# 12-monitoring/grafana/bootstrap — Terraform identity for Grafana

A standalone Terraform root that provisions the **service account identity
`12-monitoring/grafana/managed` (and any later root) uses to manage
Grafana's configuration** declaratively, instead of ad-hoc API calls against
a live instance.

Mirrors `11-secrets/openbao/bootstrap` exactly — read that root's README for
the fuller rationale of the bootstrap/managed split; this one only notes
where Grafana's story differs.

## Why its own domain, not `11-secrets/`

`11-secrets/` is IaC for **OpenBao's own configuration** — its auth methods,
mounts, policies, and secret content. Grafana is a different tool with a
different provider and its own lifecycle (dashboards, OIDC config, service
accounts); bolting it onto `11-secrets/openbao/managed` would blur that
domain's scope. `12-monitoring/` (moved from `06-monitoring/` on 2026-08-24,
see root `CLAUDE.md`'s architecture section) is its own number for the same
reason.

## Why Grafana needs no manually-supplied bootstrap secret (unlike OpenBao's `root_token`)

OpenBao's bootstrap root needs a human-supplied `root_token` because nothing
about OpenBao is Terraform state yet at that point — a genuine
chicken-and-egg. Grafana's admin password, by contrast, is **already**
Terraform-managed by `11-secrets/openbao/managed`
(`random_password.grafana_admin_password`, backing `kv/apps/grafana/admin`)
— this root just reads it via `data.terraform_remote_state` (see
`version.tf`). No copy-pasting, no chicken-and-egg.

## What it creates

- `grafana_service_account.terraform` — `role = "Admin"`. Grafana's
  service-account roles are coarse (Viewer/Editor/Admin, no fine-grained
  per-path ACL like Vault/OpenBao policies) — creating further service
  accounts/tokens requires Admin. Same reasoning as OpenBao's own
  `terraform` policy getting `sudo` on `sys/mounts`/`sys/auth`: this
  identity needs elevated rights to bootstrap structure, even though it's
  still narrower than the real human admin account.
- `grafana_service_account_token.terraform` — the token, generated once at
  apply time. `seconds_to_live` from `var.service_account_token_ttl_days`
  (default `0` — never expires; set a positive value to opt into rotation,
  unlike the forced `secret_id_ttl_days` window in the OpenBao bootstrap
  root).

## Credentials

- **`grafana` provider**: authenticates as Grafana's admin via basic auth
  (`"admin:${password}"`), password read straight from
  `11-secrets/openbao/managed`'s state — see `version.tf`. Defaults to
  Grafana's internal Service address (`http://grafana.monitoring.svc:80/`),
  reachable via the WireGuard tunnel's internal-cluster DNS + proxy-dynamic
  sidecar (`04-vpn/wireguard-site-to-site/README.md`, infrastructure#81) — same
  pattern as the `vault` provider's own default. The public route
  (`https://grafana.scalepack.fr/`) still works too if the tunnel isn't up:
  Grafana's basic-auth API path isn't gated behind the shared sso-guard edge
  policy (gitops repo's `services/platform/monitoring/grafana-gateway`
  deliberately bypasses it), same as OpenBao's own public route — just
  isn't the default anymore.
- **S3 state backend**: same AWS-style env vars as every other root (via
  `mise.toml`'s `[env]` block).

## Apply

```bash
terraform -chdir=12-monitoring/grafana/bootstrap init
terraform -chdir=12-monitoring/grafana/bootstrap workspace select -or-create 12-monitoring-grafana-bootstrap-dev
terraform -chdir=12-monitoring/grafana/bootstrap plan  -var-file=env/12-monitoring-grafana-bootstrap-dev.tfvars
terraform -chdir=12-monitoring/grafana/bootstrap apply -var-file=env/12-monitoring-grafana-bootstrap-dev.tfvars
```

> Never `terraform apply`/`destroy` here without explicit approval.

## Consuming the service account (12-monitoring/grafana/managed onward)

`12-monitoring/grafana/managed`'s own `provider "grafana"` reads
`service_account_token` straight from this root's state via
`data.terraform_remote_state` — no manual copy-paste, same as the OpenBao
bootstrap/managed pair.

## Rotation / revocation

- **Token** — force early rotation with:

  ```bash
  terraform -chdir=12-monitoring/grafana/bootstrap apply -replace=grafana_service_account_token.terraform -var-file=env/12-monitoring-grafana-bootstrap-dev.tfvars
  ```

  Re-apply `12-monitoring/grafana/managed` afterward — the old token stops
  working immediately once replaced.
- **Full revocation** — destroy `grafana_service_account.terraform`; mind
  that anything consuming it (currently just `managed/`) breaks immediately.
