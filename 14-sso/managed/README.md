# 14-sso/managed

authentik-as-code: **groups**, **forward-auth applications** (proxy provider +
application + group bindings, which is also what drives each user's per-group
"My applications" tiles) and the **embedded outpost** that serves them.

Users and their group membership are deliberately **not** declared here: this
root owns the *structure*, people are added to groups in authentik's UI or by
invitation (below).

Applied unattended by the `authentik-managed` Crossplane Workspace
(`gitops/services/platform/crossplane/config`), like `openbao-managed` and
`grafana-managed`. It authenticates with authentik's akadmin bootstrap token
(`kv/apps/authentik/credentials`, declared in `11-secrets/openbao/managed`)
over the in-cluster Service.

## Managing people

Admins are the members of a group with `is_superuser` (`platform-admins`, so the
GitHub team `admin`): they get the "Admin interface" button in authentik
(`https://sso.<domain>/if/admin/`).

| To | Where |
| --- | --- |
| See who can open what, everything on one page | Grafana, folder "Access (admins)" (`/d/sso-access`) |
| One person: groups, applications, sign-in devices | Directory > Users > the user |
| Put someone in a group / take them out | Directory > Groups > the group > Users |
| Cut someone off | Directory > Users > deactivate (also end their sessions) |
| Invite any e-mail address as a guest | Directory > Invitations > create, flow `invitation-demo` |

**Inviting.** Pick the flow (that picks the group), tick "single use", set an
expiry, optionally pre-fill `{"email": "someone@example.com"}` in the custom
attributes, create, then copy the link and send it yourself (no mail server).
The guest picks a username and registers a passkey: no password exists. A new
invitable group = an entry in `groups` + in `invitation_groups` (never a
superuser group) + in the `groups` of the apps it opens.

A GitHub login re-adds the groups the GitHub mapping returns (`github.tf`), so
removing an organization member from `platform-users` by hand does not last.

People, memberships and invitations live only in authentik's database: they
survive a cluster `down` as of the last snapshot (every 4 hours).

## The access report

`reporting.tf`: the Grafana data source (`grafana_reader`, read-only,
column-level grants, created by the gitops authentik chart), an admins-only
folder and the dashboard. Open-source Grafana cannot restrict a data source:
any Grafana user can query what the role reads (users, e-mails, groups, access)
through the API, even without seeing the dashboard. Disabled when the two
passwords are not supplied.

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
- `invitations.tf`: invitation-only enrollment, one flow per invitable group.
- `reporting.tf` + `dashboards/access.json`: the access report.
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
  tokens argocd-server rejects.

## Not here yet

- SSO on ephemeral clusters (`env_suffix`): the redirect URIs are staging-only.
