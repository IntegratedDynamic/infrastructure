# 01-iam — what this domain is for

Identities that let something outside this repo's control (CI, an
in-cluster workload) authenticate to an external system — one identity per
purpose, scoped to exactly what that purpose needs. Not `00-foundation`'s
job: the state-bucket-access role lives there because every root needs it.
This domain is for everything else.

## The two sub-splits

- **`bootstrap/`** — trust anchors and CI identities, applied once by a
  human admin. Its key job is to provide the identities that let CI/CD
  actually run every other root module: **the repo-wide default is that
  every root except `00-foundation` and a `<domain>/bootstrap/*` root is
  meant to run through CI/CD, not be applied by hand.** `bootstrap/` roots
  (like `00-foundation`) are the deliberate exception — run once, by a
  human, ideally never touched again. That the identity applying a
  `bootstrap/` root is itself admin-or-near-admin is expected;
- **`workload/`** — the fallback for a scoped identity that doesn't have
  infrastructure of its own to attach to. A domain that owns real
  infrastructure mints its identity as part of that domain (see
  `02-encryption`, `03-storage`) — `workload/` exists for the identities
  that don't have a piece of infrastructure to justify becoming their own
  numbered domain.

## The contract

- **One identity, one purpose, least privilege.** No identity here grants
  capability beyond what its one consumer needs — least-privilege scoping is
  the point of splitting these out instead of sharing a single broad key.
- **No identity here mints capability for another domain.** A domain that
  needs a new external credential gets its own entry in `bootstrap/` or
  `workload/`, not a widened grant on an existing one — the retired
  role-creates-roles system (see `00-foundation/README.md`) is what this
  rule is reacting to.
- **Keyless (OIDC or equivalent) wherever the provider supports it.**
  Fall back to a static key only when it's genuinely not possible (documented
  per-identity where that's the case, e.g. `bootstrap/scaleway/README.md`).

## What deliberately doesn't belong here

- The state-bucket-access role — that's `00-foundation`.
- An identity for infrastructure that owns its own domain — that identity
  gets minted as part of that domain instead (see `workload/`'s entry
  above).
