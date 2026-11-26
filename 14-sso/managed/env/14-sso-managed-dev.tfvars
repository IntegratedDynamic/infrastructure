# Names the OpenTofu workspace ("14-sso-managed-dev") and carries this
# workspace's non-secret configuration -- the SSO structure as code. The API
# token is a secret and arrives as TF_VAR_authentik_token, never here.

domain = "staging.scalepack.fr"

# Structure only: who is IN these groups is decided in authentik's UI.
groups = {
  "platform-admins" = {}
  "platform-users"  = {}
}

# Applications behind authentik's forward-auth. `groups` decides both who may
# launch the app and whose "My applications" page shows its tile.
applications = {
  demo = {
    name        = "Demo"
    host_prefix = "demo"
    groups      = ["platform-admins", "platform-users"]
    section     = "Products"
  }

  # Firefly III (personal finances, the homelab-apps repo). platform-admins ONLY,
  # on purpose: Firefly signs the user in from the e-mail authentik sends
  # (remote_user_guard, no validation of its own) and creates an account for any
  # e-mail it has not seen, so anyone allowed through becomes a Firefly user.
  # The e-mail MUST match the one of the existing Firefly account, exactly
  # (Postgres compares case-sensitively), else the user lands on an empty Firefly.
  firefly = {
    name        = "Firefly III"
    host_prefix = "firefly"
    groups      = ["platform-admins"]
    section     = "Personal"
  }
}

# GitHub login source. The OAuth App's Client ID/secret are NOT here: external
# secrets in kv/apps/authentik/credentials, delivered by the Workspace.
# Only ACTIVE members of this organization are put in any group; everyone else
# gets an account with no group, so no access and no tile.
github_org          = "IntegratedDynamic"
github_member_group = "platform-users"
# GitHub team slug -> authentik group (on top of the member group).
github_team_groups = {
  "admin" = "platform-admins"
}

# OIDC clients that used to log in through Dex. Secrets are NOT here (see
# oidc_client_secrets). `groups` = who may use the app; what it grants inside is
# the app's own mapping of the `groups` claim (platform-admins = admin).
# An admin must be able to use everything, so platform-admins is listed next to
# platform-users even though the GitHub mapping puts admins in both groups: a
# local account in platform-admins ONLY would otherwise be refused (seen in e2e).
oidc_clients = {
  # ONE public client for both the web UI and `argocd login --sso` (PKCE, no
  # secret; ArgoCD's enablePKCEAuthentication). Two clients cannot work here:
  # authentik's issuer is per APPLICATION (.../application/o/<slug>/), so a
  # separate CLI client issues tokens with ANOTHER issuer and argocd-server
  # rejects them ("id token issued by a different provider", seen live on the
  # first real `argocd login --sso`). There is no shared issuer to fall back to:
  # authentik serves no discovery document at the root.
  argocd = {
    name        = "ArgoCD"
    client_id   = "argocd"
    client_type = "public"
    redirect_uris = [
      "https://argocd.staging.scalepack.fr/auth/callback",
      # `argocd login --sso`'s fixed loopback port.
      "http://localhost:8085/auth/callback",
    ]
    groups     = ["platform-users", "platform-admins"]
    launch_url = "https://argocd.staging.scalepack.fr"
    section    = "Platform"
  }
  grafana = {
    name          = "Grafana"
    client_id     = "grafana"
    redirect_uris = ["https://grafana.staging.scalepack.fr/login/generic_oauth"]
    groups        = ["platform-users", "platform-admins"]
    launch_url    = "https://grafana.staging.scalepack.fr"
    section       = "Platform"
  }
  crossview = {
    name          = "Crossview"
    client_id     = "crossview"
    redirect_uris = ["https://crossview.staging.scalepack.fr/api/auth/oidc/callback"]
    groups        = ["platform-users", "platform-admins"]
    launch_url    = "https://crossview.staging.scalepack.fr"
    section       = "Platform"
  }
  # OpenBao: both the UI callback and `bao login -method=oidc`'s loopback port
  # (what the terraform-cli role uses). Admins only, as before.
  openbao = {
    name = "OpenBao"
    client_id = "openbao"
    redirect_uris = [
      "https://openbao.staging.scalepack.fr/ui/vault/auth/oidc/oidc/callback",
      "http://localhost:8250/oidc/callback",
    ]
    groups     = ["platform-admins"]
    launch_url = "https://openbao.staging.scalepack.fr/ui/"
    section    = "Platform"
  }
  # headscale: who may log a device into the private network (`tailscale up`).
  # Admins only: every member device may SSH into the CI runners being debugged
  # (gitops repo's headscale policy). PUBLIC client with PKCE, like ArgoCD: no
  # secret to generate or deliver. No UI, hence no tile.
  headscale = {
    name          = "Headscale"
    client_id     = "headscale"
    client_type   = "public"
    redirect_uris = ["https://headscale.staging.scalepack.fr/oidc/callback"]
    groups        = ["platform-admins"]
    hide_tile     = true
  }
}

