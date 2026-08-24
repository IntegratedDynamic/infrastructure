# 12-monitoring — what this domain is for

Terraform-managed configuration for the monitoring stack's own tools —
their identities and declarative config, not the tools themselves (those
are gitops-deployed, see the gitops repo's `services/platform/monitoring/`).
Moved from `06-monitoring` on 2026-08-24 to sit after `10-cluster` (see root
`CLAUDE.md`'s architecture section) — `06` is back to being an open gap.

One service lives here today: [`grafana/`](grafana/README.md), split into
two roots — `bootstrap/` mints the one service account identity everything
else authenticates as (admin-applied, rare changes), `managed/` is
Grafana's actual declarative configuration, reconciled via that service
account. Read `grafana/README.md` for the actual detail (why its own
domain, not `11-secrets/`).
