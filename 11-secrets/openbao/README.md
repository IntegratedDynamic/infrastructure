# 11-secrets/openbao — OpenBao, managed by Terraform

Two roots, split by scope, not by who applies (see infra#115 follow-up
below for why that changed):

- [`bootstrap/`](bootstrap/README.md) — a minimal Kubernetes-auth trust
  anchor Crossplane's own provider-opentofu Workspace needs to
  self-bootstrap `managed/`, its own unattended applier. Human/root-token
  applied, rare changes.
- [`managed/`](managed/README.md) — everything else: OpenBao's actual
  structure and secret content, plus the human (OIDC) and in-cluster
  (Kubernetes auth, once `bootstrap/` exists) identities that reconcile it.

## History (infra#115 follow-up, 2026-09-30)

`bootstrap/` used to mint a `terraform` AppRole identity `managed/`
authenticated as for EVERYTHING — laptop applies, a never-finished CI
plan, and the Crossplane Workspace. It was deleted entirely (part 2) after
a live break: the AppRole's `secret_id` — generated once, "rotate by
tainting" never actually run — had been silently purged by OpenBao
itself. Investigating the fix turned up that AppRole's own justification
("a service/pipeline authenticating without a human in the loop") never
matched either of `managed/`'s real execution contexts:

- An admin's laptop is a human, at an interactive session — OIDC via Dex
  (`managed/`'s `terraform-cli` role) was already the established pattern
  everywhere else on this platform, just never wired into this specific
  provider config.
- The Crossplane Workspace is a real pod in a trusted cluster — Kubernetes
  auth needs no secret to manage at all.

Switching Crossplane to Kubernetes auth then surfaced a NEW
chicken-and-egg (part 3): unlike a laptop admin, who always has
`var.root_token` as a one-off bootstrap escape hatch, an unattended
Workspace never has a root token available to it — so if its own trust
anchor lived inside `managed/`, creating it would need `managed/` already
applied. `bootstrap/` came back, minimal, specifically to close that one
loop — see its own README for exactly what it creates and why.

No CI workflow applies either root today (confirmed: no real reference in
`.github/workflows/`) — the documented-but-never-finished AppRole-based
"CI feedback loop" this README used to describe is moot now that there's
no AppRole to round-trip. If CI ever does need to run `managed/` directly,
the right mechanism is GitHub Actions' own OIDC federation straight to
OpenBao (mirroring `13-tailscale/bootstrap`'s and `00-foundation/aws`'s
existing GitHub OIDC trust) — not reviving AppRole.
