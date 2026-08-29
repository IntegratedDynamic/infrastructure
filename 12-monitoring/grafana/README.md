# 12-monitoring/grafana — Grafana, managed by Terraform

One root:

- [`managed/`](managed/README.md) — Grafana's actual declarative
  configuration (service accounts, data sources, dashboards), reconciled
  by authenticating directly as Grafana's admin.

There used to be a `bootstrap/` root here (mirroring
`11-secrets/openbao/bootstrap`) that minted a `terraform` service-account
token for `managed/`'s provider to use. It was removed: that token could
stop authenticating after a Velero restore while still showing valid in
Grafana's metadata (infra#82 mode 1), and Grafana — unlike OpenBao — has
no chicken-and-egg that forces a bootstrap step. `managed/` now
authenticates as the admin password `11-secrets/openbao/managed` already
owns and regenerates on every restore.

## Why its own domain, not `11-secrets/`

`11-secrets/` is IaC for **OpenBao's own configuration** — its auth
methods, mounts, policies, and secret content, nothing else. Grafana is a
different tool with a different provider and its own lifecycle (dashboards,
OIDC config, service accounts) — bolting it onto `11-secrets/openbao/managed`
would blur that domain's scope the same way `02-encryption/aws` stayed out
of `03-storage/scaleway` (different provider/pattern, not "storage").
`12-monitoring/` (moved from `06-monitoring/` on 2026-08-24, see root
`CLAUDE.md`'s architecture section) is its own number for the same reason —
a distinct domain, not folded into `11-secrets/`.

## Why no bootstrap step (unlike OpenBao's `root_token`)

OpenBao's own `bootstrap/` needs a human-supplied root token because
nothing about OpenBao is Terraform state yet at that point — a genuine
chicken-and-egg (see `../../11-secrets/openbao/README.md`'s self-init
section). Grafana doesn't have that problem: its admin password is
**already** owned by `11-secrets/openbao/managed`
(`random_password.grafana_admin_password` → `kv/apps/grafana/admin`).
`managed/` authenticates as that admin directly, taking the password as the
env var `TF_VAR_grafana_admin_password` (from the ESO-synced
`crossplane-grafana-admin` Secret in-cluster, or `bao kv get` locally). No
minted trust anchor, no copy-pasting, no separate chicken-and-egg.

## The credential path

Nothing new to round-trip through ESO for the admin password — it's already
in OpenBao KV, and the Crossplane `crossplane-config` chart syncs
`kv/apps/grafana/admin` into a Secret the Workspace maps to
`TF_VAR_grafana_admin_password`, exactly like it does for
`openbao-managed`'s own required `TF_VAR_*` inputs. `12-monitoring/grafana/managed`
is CI-appliable in principle from day one (export the same env var), same
"designed for it, not yet wired to an actual workflow" status
`11-secrets/openbao/managed` itself currently has (no `.github/workflows/*`
references for this root today — applied by hand for now).
