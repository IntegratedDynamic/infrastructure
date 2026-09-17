# 13-tailscale/bootstrap — Tailscale CI-debug trust anchor

Provisions the Tailscale side of live GitHub Actions debugging (infra#110):
a tailnet ACL granting SSH from this tailnet's own member devices to any
node tagged `tag:ci-debug`, plus an **OIDC workload identity federation**
trust (`tailscale_federated_identity`) that lets GitHub Actions join the
tailnet directly with its own per-run OIDC token — no static authkey or
OAuth secret ever has to be stored as a GitHub secret.

This replaces an earlier upterm-based approach entirely, and an even
earlier version of this same root that used a plain reusable
`tailscale_tailnet_key` (`TS_AUTHKEY`) — dropped in favor of OIDC
federation once it became clear Tailscale supports it directly, the same
keyless pattern this repo already uses for AWS (`01-iam/bootstrap/aws`'s
OIDC-trusted role). See the root `CLAUDE.md`'s "Live debugging via
Tailscale SSH" section for the full picture.

A `01-iam/bootstrap/` trust anchor (human-applied, rare changes) in spirit,
but kept as its own top-level domain (`13-tailscale/`) rather than folded
into `01-iam/` — this isn't a Scaleway identity, and while it's a single
flat root today, `13-tailscale/workload/` is a natural place to add scoped
per-project Tailscale identities later without a restructure, the same
`bootstrap/`-vs-`workload/` split `01-iam/` already uses.

## Bootstrap credentials

There's no way to create the very first Tailscale credential via Terraform
— same chicken-and-egg every other bootstrap root in this repo has (e.g.
`01-iam/bootstrap/aws`). One-time, by hand:

1. In the Tailscale admin console → **Settings → Keys**, generate a
   personal **API access token** (not a reusable device auth key). This
   acts with your own account's admin rights, so it's simpler to set up
   than scoping an OAuth client for a credential that's only ever used
   locally and occasionally — no scope-picker UI to get right.
2. Write it into a gitignored per-developer file (matches `*.auto.tfvars`
   already in `.gitignore` — same shape as `10-cluster/scaleway`'s
   `local.auto.tfvars`):

   ```hcl
   # 13-tailscale/bootstrap/nico.auto.tfvars — gitignored, never commit
   api_key = "tskey-api-..."
   ```
3. Tailscale enforces an expiry on personal API keys (~90 days) — when it
   lapses, generate a new one and overwrite the same `*.auto.tfvars` line.
   No `tofu apply` is needed just for this (the key isn't Terraform state,
   it's only how *you* authenticate to run Terraform).

## First apply

`tailscale_acl.this` uses `overwrite_existing_content = true`, which
**replaces whatever ACL currently exists in the tailnet** — it does not
merge. Before the first apply, check the tailnet's current policy file
(admin console → Access Controls) and fold anything load-bearing into
`main.tf`'s `acl` block yourself; this root's own `acl` only encodes a
default-open `acls` grant plus the `tag:ci-debug` SSH grant, nothing else.

```bash
tofu -chdir=13-tailscale/bootstrap init
tofu -chdir=13-tailscale/bootstrap plan    # review first -- check the ACL diff carefully
tofu -chdir=13-tailscale/bootstrap apply
```

> Never `tofu apply`/`destroy` here without explicit approval — this
> mutates a shared tailnet-wide access policy, not just this root's own
> resources.

## Wiring the GitHub repo variables (manual)

`ci_debug_oauth_client_id` and `ci_debug_audience` are **not secrets** — a
federated identity's client ID can't authenticate on its own; it also
needs a real GitHub Actions OIDC token matching this resource's
issuer/subject/audience, which only GitHub itself can mint per job. Same
reasoning this repo already applies to `AWS_TERRAFORM_ROLE_ARN` (a plain
repo variable, not a secret). Set them once:

```bash
gh variable set TS_OAUTH_CLIENT_ID \
  --repo IntegratedDynamic/infrastructure \
  --body "$(tofu -chdir=13-tailscale/bootstrap output -raw ci_debug_oauth_client_id)"

gh variable set TS_AUDIENCE \
  --repo IntegratedDynamic/infrastructure \
  --body "$(tofu -chdir=13-tailscale/bootstrap output -raw ci_debug_audience)"
```

No rotation step needed afterward — there's no bearer secret to expire;
GitHub mints a fresh, short-lived OIDC token for every job automatically.

## Connecting to a debugged runner

See `.github/actions/debug-tailscale/action.yml` and the root `CLAUDE.md`'s
"Live debugging via Tailscale SSH" section — once your own machine has
`tailscale` installed and is logged into this same tailnet, it's just
`ssh runner@<job>-<run_id>` (or `tailscale ssh runner@<hostname>`) --
`runner` because that's the actual local user on a GitHub-hosted runner,
confirmed live 2026-09-17 (a plain `ssh <hostname>` defaults to your own
local username and fails with `tailscale: failed to look up local user`).
No wrapper
scripts.
