# 06-monitoring — what this domain is for

Terraform-managed configuration for the monitoring stack's own tools —
their identities and declarative config, not the tools themselves (those
are gitops-deployed, see the gitops repo's `services/platform/monitoring/`).
The first of CLAUDE.md's deliberately gapped `06`-`09` domain numbers.

One service lives here today: [`grafana/`](grafana/README.md), split into
two roots — `bootstrap/` mints the one service account identity everything
else authenticates as (admin-applied, rare changes), `managed/` is
Grafana's actual declarative configuration, reconciled via that service
account. Read `grafana/README.md` for the actual detail (why its own
domain, not `05-secrets/`).
