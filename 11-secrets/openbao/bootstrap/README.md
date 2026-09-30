# 11-secrets/openbao/bootstrap — Kubernetes-auth trust anchor for Crossplane

A standalone Terraform root that exists for one reason: **Crossplane's own
provider-opentofu Workspace controller needs to authenticate to OpenBao
before it can run `tofu apply` on `11-secrets/openbao/managed`** — and
that Workspace IS `managed/`'s own unattended applier, so its trust anchor
can't live inside `managed/` itself without becoming circular (creating it
would require a successful `managed/` apply, which requires authenticating
first). This root breaks that loop, minimally.

## History (infra#115 follow-up, 2026-09-30)

This root used to mint a `terraform` AppRole identity `managed/`
authenticated as for everything — laptop applies, CI (never actually
wired up), and Crossplane. It was deleted entirely (part 2 of this
follow-up) after a live break: the AppRole's `secret_id` had been silently
purged by OpenBao, and investigating the fix turned up that AppRole's
actual justification — "a service/pipeline authenticating without a human
in the loop" — never matched either of `managed/`'s real execution
contexts. An admin's laptop is a human (OIDC via Dex, `managed/`'s own
`terraform-cli` role, is the same pattern already used everywhere else on
this platform). Crossplane's Workspace is a real pod in a trusted cluster
(Kubernetes auth — no secret to manage at all).

Switching Crossplane to Kubernetes auth (part 3, this root) then surfaced
a NEW chicken-and-egg: unlike an admin's laptop (which always has
`var.root_token` as a one-off bootstrap escape hatch), an unattended
Workspace never has a root token available to it. So `managed/` alone
can't fully self-bootstrap Crossplane's own trust anchor — something has
to exist first. This root is that something: as narrow as it can be while
still closing the loop.

## What it creates

- `vault_policy.terraform` — the SAME policy content the AppRole identity
  used to get: scoped to structure (mounts, auth methods, roles, policies)
  and `kv/apps/*` secret content, no `sudo path "*"`, no delete on
  `kv/data|metadata/apps/*`.
- `vault_auth_backend.kubernetes` + `vault_kubernetes_auth_backend_config.kubernetes`
  — the Kubernetes auth mount itself, pointed at this cluster's own API
  server. `managed/`'s OWN two other Kubernetes-auth roles (`snapshot`,
  `external-secrets`) reference this SAME mount by its literal path
  (`"kubernetes"`), not a resource reference — cross-root, different
  state, same pattern this root's old AppRole/policy used before.
- `vault_kubernetes_auth_backend_role.crossplane` — bound to
  `provider-opentofu`'s own ServiceAccount (`crossplane-system`; that name
  is pinned deterministically by the gitops repo's
  `services/platform/crossplane/chart` `DeploymentRuntimeConfig`, not
  revision-hashed, specifically so this binding survives a provider
  upgrade), granted `vault_policy.terraform`.

Everything else OpenBao needs — the KV mount, the human `admin`/
`terraform-cli` OIDC roles, secret content — lives in `managed/`, applied
by a human (this root's `var.root_token`, or `managed/`'s own once this
root exists) the first time, and by either a human (OIDC) or Crossplane
(Kubernetes auth, now bootstrapped) from then on.

## Credentials

- **`vault` provider**: always authenticates as `var.root_token` — the one
  genuinely unavoidable use of a raw root/admin token on this whole
  platform (every other root exists specifically so IT doesn't need one).
  Pass via `TF_VAR_root_token`, never a CLI flag:

  ```bash
  export TF_VAR_root_token="<root token>"
  ```
- **S3 state backend**: same AWS-style env vars as every other Scaleway-
  hosted root (`export AWS_ACCESS_KEY_ID=$(scw config get access-key)`
  etc. — see the repo root `CLAUDE.md`'s Setup section).
- **`var.vault_address`**: defaults to the in-cluster Service
  (`http://openbao.openbao.svc:8200/`), reachable via a WireGuard tunnel
  or `kubectl port-forward -n openbao openbao-0 <local-port>:8200` — pass
  `-var vault_address=http://127.0.0.1:<local-port>/` for the latter.

## Apply

```bash
cd 11-secrets/openbao/bootstrap
tofu init
tofu workspace select -or-create 11-secrets-openbao-bootstrap-dev
tofu plan  -var-file=env/11-secrets-openbao-bootstrap-dev.tfvars    # review first
tofu apply -var-file=env/11-secrets-openbao-bootstrap-dev.tfvars
```

> Never `tofu apply`/`destroy` here without explicit approval — this is a
> root-token-authenticated root against real OpenBao.

Confirmed live (2026-09-30, ephemeral cluster pr-116): applies and
destroys cleanly against a restored OpenBao snapshot.
