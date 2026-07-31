# 00-foundation — what this domain is for

This root module is the foundation for all the infrastructure managed by
this repository. Concretely, it requires exactly two things:

- A remote state solution (e.g. S3)
- Whatever setup lets Terraform, running from your CI/CD, access and operate
  that state

That state is the foundation for everything else your infrastructure
manages — every resource you've deployed, your backups, your encryption
keys, all of it lives there.

## Why this domain matters more than its size suggests

Not just "holds a Terraform state bucket." This repo bootstraps its entire
infrastructure — including the cluster and ArgoCD, which then takes over
everything downstream — via Terraform. That choice makes remote state the
only trusted source of truth for what's actually deployed. It's also why
this domain has to be the first thing applied: every other root's backend
points at the bucket this one creates, so nothing else can even exist yet
until this does.

## The contract

A `00-foundation/<provider>` root must provide exactly these things, and
nothing that isn't required to provide them:

1. **A durable, versioned store for Terraform state**, reachable by every
   other root's backend configuration. It must survive the loss of any single
   developer's machine or CI runner, support recovering a corrupted/truncated
   write (versioning or equivalent), and deny non-encrypted-in-transit access.
2. **Protection against concurrent writes** to the same root's state, so two
   `plan`/`apply` runs racing each other can't corrupt it. A lock is the
   common shape this takes; other [locking strategies](https://developer.hashicorp.com/terraform/language/state/locking)
   exist.
3. **One CI identity**, trusted keylessly if the provider supports it (OIDC
   or equivalent — a strong machine-to-machine auth pattern, preferred over
   long-lived static credentials wherever the provider supports it), scoped
   to **read/write access on the state store from step 1, and nothing else**.
   In particular: no general credential- or identity-management capability. A
   domain that needs its own CI identity for provider-specific reasons beyond
   state R/W (e.g. `02-encryption/aws` needing KMS/IAM rights) gets its
   **own**, separately and narrowly scoped identity elsewhere —
   `00-foundation` is not the place that mints capability for other domains.

   **Known limitation:** this identity is scoped to the whole state bucket,
   not per-root. The AWS implementation trusts OIDC from exactly this repo,
   on the assumption that every Terraform root in the org lives here — but
   within the repo, there is no isolation between roots at the state layer.
   A workflow authorized to touch one root's state can, at the
   IAM-permission level, touch any other root's state too. Deliberate
   trade-off (per-root scoping is more machinery than a homelab-scale org
   needs), not an oversight.

4. **Must be executable locally.** This root creates the very store its own
   state ends up living in — a chicken-and-egg every implementation has to
   solve explicitly, and the state bucket obviously can't be relied on yet
   to do it. What matters is that it can be run once, by an admin, on their
   own machine, to get past that bootstrap — and ideally never needs to be
   touched again after.

## Adding a new provider

A domain with only one provider still nests under it (`00-foundation/aws/`),
so a second provider (e.g. `00-foundation/scaleway/` if a state backend ever
needs to exist there) can be added later without restructuring existing
roots. Each provider's root is independent — there's no requirement that they
share a state store; each just has to satisfy the contract above for its own
provider.
