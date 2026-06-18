# 01-iam/infisical — GitHub Actions → Infisical (OIDC)

A standalone Terraform root that sets up **keyless GitHub-OIDC → Infisical**: a
dedicated Infisical machine identity that GitHub Actions authenticates as by
presenting its short-lived OIDC token — no long-lived Infisical secret stored in
CI.

This is the keyless counterpart to [`01-iam/scaleway`](../scaleway) (which has to
use a static API key because Scaleway IAM isn't an OIDC relying party). Infisical
**is**, so we get the real keyless flow here.

## How the flow works

1. A workflow run requests an OIDC token from GitHub (`permissions: id-token: write`).
2. The workflow logs in to Infisical with that token + the identity ID.
3. Infisical verifies the token against GitHub's JWKS (`oidc_discovery_url`),
   checks `iss` (`bound_issuer`), `aud` (`bound_audiences`) and `sub`
   (`bound_claims.sub` = `repo:IntegratedDynamic/infrastructure:*`), then returns
   a short-lived Infisical access token (`access_token_ttl`, default 600s).
4. With that token the workflow reads secrets from the **Platform** project (the
   identity is granted the read-only `viewer` project role).

## What it creates

- `infisical_identity.github_actions` — the CI identity (org-level role
  `no-access`; real permissions come from the project membership, not org-wide).
- `infisical_identity_oidc_auth.github_actions` — the OIDC trust: GitHub issuer +
  discovery URL, bound audience, and `sub` scoped to this one repo (any
  branch/PR/tag).
- `infisical_project_identity.github_actions` — grants the identity the `viewer`
  role on the Platform project so CI can read its secrets.

## The bootstrap chicken-and-egg

Creating an OIDC identity still requires an authenticated provider, so this root
authenticates with a **universal-auth machine identity** (`client_id` /
`client_secret` in `default.auto.tfvars`, gitignored, per-developer). That
bootstrap identity is the seed; once this OIDC identity exists, CI authenticates
with it instead of any static secret.

## Credentials

- **Infisical** provider — universal-auth machine identity from
  `*.auto.tfvars`. Host defaults to `https://app.infisical.com`.
- **S3 state backend** — AWS-style env vars (injected by `mise.toml`'s `[env]`
  block like the other roots).

## Apply

```bash
terraform -chdir=01-iam/infisical init
terraform -chdir=01-iam/infisical plan  -var-file=env/01-iam-infisical.tfvars
terraform -chdir=01-iam/infisical apply -var-file=env/01-iam-infisical.tfvars
```

> Never `apply`/`destroy` here without explicit approval.

After apply, `terraform output identity_id` is the principal GitHub Actions logs
in as — wire it into the workflow (e.g. as a repo variable).

## Wiring a workflow (example)

```yaml
permissions:
  id-token: write
  contents: read
steps:
  - uses: Infisical/secrets-action@v1
    with:
      method: oidc
      identity-id: ${{ vars.INFISICAL_IDENTITY_ID }}   # = output identity_id
      project-slug: platform-p-qc1
      env-slug: staging
      secret-path: /ci
```

The OIDC token's default `aud` is `https://github.com/IntegratedDynamic`
(matching `github_oidc_audience`); if the workflow requests a custom audience,
update that variable to match or login is rejected.

## Trust scope / revocation

- Trust is pinned to `repo:IntegratedDynamic/infrastructure:*` — only workflows
  in this repo can authenticate. Narrow it further (e.g. a single branch) by
  tightening `bound_claims.sub`.
- To revoke access, destroy the identity (or remove the project membership to
  drop project access while keeping the identity).
