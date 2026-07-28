# 05-secrets/openbao/bootstrap — Terraform identity for OpenBao

A standalone Terraform root that provisions the **AppRole identity
`05-secrets/openbao/managed` (and any later root) uses to manage OpenBao's
internal configuration** declaratively (auth methods, mounts, ACL policies),
instead of the `bao` CLI one-off commands this cluster's config relied on
originally (see the gitops repo's `openbao-claude.md` for that history).

See [`../README.md`](../README.md) for the self-init pattern this root
implements — read it before changing anything here.

## Why its own domain, not `01-iam/`

`01-iam/` provisions identities for **external** systems Terraform talks to
(AWS, Scaleway, Infisical) so CI/humans can authenticate to them — none of
those depend on the cluster existing. OpenBao only exists *because* `02-cluster/`
stood it up first, so managing it declarativement has a strictly later lifecycle
than the cluster domain. Hence `05-secrets/` — its own domain, numbered above
`02-cluster/` on purpose.

`bootstrap/` (not `ci-managed/`) because creating this AppRole itself needs a
human admin credential (OIDC admin token, or the root token) — the same
human/admin-applied trust-anchor pattern as `01-iam/bootstrap/aws` and
`01-iam/bootstrap/scaleway`. A later `05-secrets/ci-managed/*` root could
consume this AppRole if declarative OpenBao management ever moves into CI.

## Why AppRole and not OIDC

OpenBao's OIDC auth (`auth/oidc`, via Dex) is wired for **human** login only —
short-lived browser-flow tokens tied to a person. AppRole is Vault/OpenBao's
purpose-built machine-auth mechanism: a `role_id` (non-secret) + `secret_id`
(secret) pair, long-lived, meant for exactly this — a service/pipeline
authenticating without a human in the loop.

## What it creates

- `vault_auth_backend.approle` — mounts `approle/` (not yet enabled on this
  OpenBao instance as of this root's creation).
- `vault_policy.terraform` — scoped to **structure only**:
  `sys/mounts/*`, `sys/auth/*` (both `sudo`-capable — Vault/OpenBao
  root-protects mount/unmount), `auth/*` (backend config + roles, e.g.
  `auth/kubernetes/role/*`), `sys/policies/acl/*`. Deliberately **excludes**
  `kv/data/*` / `kv/metadata/*` — this identity can reshape what's mounted and
  how auth/policies are wired, but cannot read any existing secret value.
- `vault_approle_auth_backend_role.terraform` — role `terraform`, bound to the
  policy above. `token_ttl` / `token_max_ttl` / `secret_id_ttl` are
  `var`-configurable (defaults: 1h / 4h / 90 days).
- `vault_approle_auth_backend_role_secret_id.terraform` — the `secret_id`,
  generated once at apply time. State-only, same bootstrap model as the
  Scaleway API key in `01-iam/bootstrap/scaleway`.

## Credentials

- **`vault` provider**: `address` is hardcoded in `version.tf` — OpenBao's own
  CLI reads `BAO_ADDR`/`BAO_TOKEN`, not Vault's `VAULT_ADDR`/`VAULT_TOKEN`, so
  a `bao login` session never populates the env var this (Vault-lineage)
  provider looks for; hardcoding the address sidesteps that mismatch. Only
  the token comes from the environment. Use your OIDC admin session:

  ```bash
  export VAULT_TOKEN="$(cat ~/.vault-token)"   # after `bao login -method=oidc`, role admin, TTL ~1h
  ```

  Re-run `bao login -method=oidc` (interactive, browser-based — Claude cannot
  drive it) whenever the token expires. `var.root_token` (see `../README.md`)
  works too, but prefer OIDC once it's wired up.
- **S3 state backend**: same AWS-style env vars as every other root (via
  `mise.toml`'s `[env]` block).

## Apply

```bash
terraform -chdir=05-secrets/openbao/bootstrap init
terraform -chdir=05-secrets/openbao/bootstrap workspace select -or-create 05-secrets-openbao
terraform -chdir=05-secrets/openbao/bootstrap plan  -var-file=env/05-secrets-openbao.tfvars    # review first
terraform -chdir=05-secrets/openbao/bootstrap apply -var-file=env/05-secrets-openbao.tfvars    # mounts approle/, creates policy+role+secret_id
```

> Never `terraform apply`/`destroy` here without explicit approval.

## Consuming the AppRole (05-secrets/openbao/managed onward)

```bash
terraform -chdir=05-secrets/openbao/bootstrap output -raw role_id
terraform -chdir=05-secrets/openbao/bootstrap output -raw secret_id   # sensitive — don't paste into shell history
```

The consuming root's `local.auto.tfvars` (per-developer, gitignored — same
convention as `02-cluster/scaleway/local.auto.tfvars`) should hold these two
values, and its own `provider "vault" {}` should authenticate via
`vault_approle_auth_backend_login` (or the equivalent `VAULT_ROLE_ID`/
`VAULT_SECRET_ID` env vars the provider reads natively) rather than a static
token.

## Rotation / revocation

- **`secret_id`** — no built-in expiry enforced by OpenBao by default; this
  root sets `secret_id_ttl` (default 90 days, `var.secret_id_ttl_days`) so it
  stops being usable after that window. Force early rotation with:

  ```bash
  terraform -chdir=05-secrets/openbao/bootstrap apply -replace=vault_approle_auth_backend_role_secret_id.terraform -var-file=env/05-secrets-openbao.tfvars
  ```

  Re-run the "Consuming the AppRole" step afterward — the old `secret_id`
  stops working once it expires (or immediately, if you also revoke it via
  `bao write auth/approle/role/terraform/secret-id-accessor/destroy accessor=<accessor>`).
- **Full revocation** — destroy the role (`vault_approle_auth_backend_role.terraform`)
  or the whole mount; mind that anything consuming the AppRole breaks
  immediately.
