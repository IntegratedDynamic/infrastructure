# 05-secrets/openbao — OpenBao, managed by Terraform

Two roots, split by who/how they're applied:

- [`bootstrap/`](bootstrap/README.md) — mints the `terraform` AppRole
  identity. Human/admin-applied, rare changes.
- [`managed/`](managed/README.md) — OpenBao's actual structure and secret
  content, reconciled via that AppRole.

## The self-init pattern

Both roots exist because of OpenBao's own [self-init RFC](https://openbao.org/community/rfcs/self-init/):
on a fresh OpenBao, nothing but the root token (minted once at `bao operator
init`) can create auth methods or policies — but the root token should never
be a standing credential anything ongoing authenticates with. So: spend the
root token **once**, in `bootstrap/`, to mint a proper machine identity (the
`terraform` AppRole) scoped to "manage OpenBao's own structure" — then
`managed/` (and any later root here) authenticates via that AppRole, never
the root token again.

## The CI feedback loop

`managed/` is meant to run from CI (GitHub Actions), same as every other root
— but CI needs the AppRole `role_id`/`secret_id` from `bootstrap/` to
authenticate, and those credentials have to come from *somewhere*. This is a
second chicken-and-egg, on top of self-init, and it's worth spelling out
because it spans two repos:

1. **Human, once**: apply `bootstrap/` (mints the AppRole).
2. **Human, once**: apply `managed/` manually, via `kubectl port-forward` to
   OpenBao directly — not through the public gateway, since at this point
   OpenBao holds no secrets yet and there's nothing worth protecting behind
   OIDC/TLS. This first apply should also merge the AppRole `role_id`/
   `secret_id` into `kv/apps/secrets-sync/github/infrastructure-scaleway`
   (alongside whatever else that KV object holds) — **not yet wired**: today
   `secrets_sync_github_infrastructure_scaleway` in `managed/main.tf` only
   merges `SCW_ACCESS_KEY`/`SCW_SECRET_KEY`.
3. **From then on, automatic**: the gitops repo's `apps/secrets-sync` (ESO)
   reads that KV path from OpenBao and pushes it to
   `github.com/IntegratedDynamic/infrastructure`'s `scaleway` environment
   secrets. CI can now authenticate to OpenBao on its own — the credentials
   it needs were themselves sourced from OpenBao, round-tripped through ESO
   and GitHub.

The loop only needs closing by hand once per environment. If it ever breaks
(AppRole `secret_id` rotated/expired with nothing to push a fresh one), it's
the same manual sequence again: port-forward, apply by hand, let ESO
re-propagate.

This isn't OpenBao-specific — any future `05-secrets/<service>/managed` root
that CI is meant to run needs the same loop: a human bootstraps it once
through a direct connection, and whatever credential CI needs to run it going
forward gets fed back out to CI through ESO, sourced from the secret manager
itself.
