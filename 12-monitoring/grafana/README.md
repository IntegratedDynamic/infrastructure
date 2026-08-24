# 12-monitoring/grafana — Grafana, managed by Terraform

Two roots, split by who/how they're applied — same shape as
`11-secrets/openbao/{bootstrap,managed}`:

- [`bootstrap/`](bootstrap/README.md) — mints the `terraform` service
  account identity. Human/admin-applied, rare changes.
- [`managed/`](managed/README.md) — Grafana's actual declarative
  configuration, reconciled via that service account.

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

## Why bootstrap needs no manually-supplied secret (unlike OpenBao's `root_token`)

OpenBao's own `bootstrap/` needs a human-supplied root token because
nothing about OpenBao is Terraform state yet at that point — a genuine
chicken-and-egg (see `../../11-secrets/openbao/README.md`'s self-init
section). Grafana doesn't have that problem: its admin password is
**already** Terraform-managed, by `11-secrets/openbao/managed`
(`random_password.grafana_admin_password`) — `12-monitoring/grafana/bootstrap`
just reads it via `data.terraform_remote_state`. No copy-pasting, no
separate chicken-and-egg to solve.

## The CI feedback loop

None needed, beyond what already exists — unlike OpenBao's own `managed/`
root (see its README's "CI feedback loop" section), nothing new has to be
round-tripped through ESO here:

- `12-monitoring/grafana/managed`'s `vault` provider reuses the *same*
  `terraform` AppRole `11-secrets/openbao/managed` already authenticates
  as — that loop is already closed.
- Its `grafana` provider authenticates via a plain
  `data.terraform_remote_state` read of `bootstrap`'s own state (an S3
  read, not a live credential exchange) — CI already has the
  `terraform-state-access` role for exactly this, no new secret needs to
  reach it.

So `12-monitoring/grafana/managed` is CI-appliable in principle from day
one, same "designed for it, not yet wired to an actual workflow" status
`11-secrets/openbao/managed` itself currently has (no `.github/workflows/*`
references either root today — both are applied by hand for now).
