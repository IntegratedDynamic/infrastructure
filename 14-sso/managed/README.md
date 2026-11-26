# 14-sso/managed

authentik-as-code: **groups**, **forward-auth applications** (proxy provider +
application + group bindings, which is also what drives each user's per-group
"My applications" tiles) and the **embedded outpost** that serves them.

Users and their group membership are deliberately **not** declared here: this
root owns the *structure*, people are added to groups in authentik's UI.

Applied unattended by the `authentik-managed` Crossplane Workspace
(`gitops/services/platform/crossplane/config`), like `openbao-managed` and
`grafana-managed`. It authenticates with authentik's akadmin bootstrap token
(`kv/apps/authentik/credentials`, declared in `11-secrets/openbao/managed`)
over the in-cluster Service.

## Adding an app behind SSO

1. Add an entry to `applications` in `env/14-sso-managed-dev.tfvars`
   (`host_prefix`, allowed `groups`).
2. In the app's own chart, include `charts/sso-guard` (`auth.enabled: true`,
   `auth.hostname`): it adds the extAuth policy and the outpost route.

## Why one `authentik_outpost` resource

The embedded outpost is imported and owns its whole provider list. The
per-provider `authentik_outpost_provider_attachment` resource is a
read-modify-write of that list: several created in parallel overwrite each
other and leave a single provider attached (reproduced on kind).

## What it declares

- `main.tf`: groups, forward-auth applications (`applications`) and the embedded outpost.
- `github.tf`: the GitHub login source (its OAuth App is created by hand;
  callback `https://sso.<domain>/source/oauth/callback/github/`), the
  org/team -> group mapping, and users enrolled through a source being
  `internal` (external users cannot open the tile page).
- `login.tf`: the login page (authentik's default identification stage,
  imported): which sources it lists and the passkey entries.
- `passkey.tf`: passkeys. A signed-in user adds one in their settings ("MFA
  devices" > "Passkey"); the login page then offers it (autofill on the
  username field, plus a "passwordless" link) so GitHub is no longer needed
  for that user. Discoverable credential + user verification are required, so
  one passkey is enough on its own. It adds a way to sign in to an EXISTING
  account, never a way to create one. A passkey is bound to the hostname
  (`sso.<domain>`): renaming the domain means adding a new one.
- `oidc.tf`: the OIDC providers of the platform's own apps (`oidc_clients`).
  ArgoCD is ONE public PKCE client for the UI and `argocd login --sso`:
  authentik's issuer is per application, so a separate CLI client issues
  tokens argocd-server rejects. headscale (the self-hosted Tailscale control
  server) is a public PKCE client too, restricted to `platform-admins`: who is in
  that group decides who may log a device into the private network.

## Not here yet

- SSO on ephemeral clusters (`env_suffix`): the redirect URIs are staging-only.
