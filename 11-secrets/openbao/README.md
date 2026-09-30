# 11-secrets/openbao — OpenBao, managed by Terraform

One root: [`managed/`](managed/README.md) — OpenBao's actual structure and
secret content.

`bootstrap/` (which used to mint a `terraform` AppRole identity `managed/`
authenticated as) was deleted entirely 2026-09-30 (infra#115 follow-up —
see `managed/version.tf`'s own `vault_auth_method` comment for the full
incident and rationale). Investigating a live break (the AppRole's
`secret_id`, generated once and never rotated, had been silently purged by
OpenBao itself) turned up that AppRole's whole justification — "a
service/pipeline authenticating without a human in the loop" — never
actually matched either of `managed/`'s real execution contexts: the
in-cluster Crossplane Workspace (a real pod, now authenticated via
Kubernetes auth — no secret to manage at all) and an admin's laptop (a
real human, now authenticated via OIDC through Dex — the same pattern
already used everywhere else in this platform). No static, easy-to-forget
credential was actually needed anywhere.

## Auth methods `managed/` authenticates with

See `managed/README.md`'s own "Credentials" section and
`managed/version.tf`'s `var.vault_auth_method` for the full detail:

- **`"oidc"`** (default) — an admin's laptop, interactive browser login via
  Dex. Its own role (`terraform-cli`), deliberately narrower than the human
  `admin` OIDC role (full `sys/*` sudo) — same `terraform` policy scope
  AppRole used to grant.
- **`"kubernetes"`** — the in-cluster Crossplane Workspace
  (`provider-opentofu`'s own ServiceAccount).
- **`var.root_token`** — an explicit emergency/bootstrap override (not a
  third "method"): takes priority over `vault_auth_method` whenever set.
  Needed for the genuine chicken-and-egg moments the retired self-init RFC
  pattern used to solve with the AppRole dance below — e.g. the very first
  `tofu apply` of `managed/` against a fresh OpenBao, before either the
  `terraform-cli` OIDC role or the `crossplane` Kubernetes role exists for
  anything to log into.

## What used to live here (historical, for context)

Both roots used to exist because of OpenBao's own [self-init
RFC](https://openbao.org/community/rfcs/self-init/): on a fresh OpenBao,
nothing but the root token can create auth methods or policies, but the
root token shouldn't be a standing credential anything ongoing
authenticates with — so `bootstrap/` spent the root token once to mint a
proper machine identity (`terraform` AppRole), and `managed/` authenticated
via that AppRole from then on. `managed/` was also meant to run from CI
(GitHub Actions) someday — "the CI feedback loop" this README used to
document was a second chicken-and-egg on top of that: CI would need the
AppRole's own `role_id`/`secret_id`, round-tripped out to GitHub Actions
secrets via OpenBao KV + ESO. That loop was never actually finished being
wired (confirmed 2026-09-30: no GitHub Actions workflow applies this root
today, and the KV object the plan named never actually got the AppRole
credentials merged into it) — moot now that there's no AppRole to
round-trip in the first place.

If CI ever does need to run `managed/` directly, the right mechanism is
GitHub Actions' own OIDC federation straight to OpenBao (a new
`vault_jwt_auth_backend_role` bound to `token.actions.githubusercontent.com`,
mirroring `13-tailscale/bootstrap`'s and `00-foundation/aws`'s existing
GitHub OIDC trust) — not reviving AppRole. Same reasoning as the laptop/
in-cluster cases above: a self-rotating identity CI already has natively,
not a new static secret for this repo to manage.
