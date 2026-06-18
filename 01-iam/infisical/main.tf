# GitHub Actions → Infisical, keyless via OIDC.
#
# A workflow run gets a short-lived OIDC token from GitHub; Infisical verifies it
# against GitHub's JWKS and trades it for an Infisical access token — so CI holds
# no long-lived Infisical credential. This is the keyless counterpart to
# 01-iam/scaleway's static API key.
#
# Bootstrap note: creating this identity still needs the universal-auth machine
# identity wired into the provider (default.auto.tfvars). That bootstrap identity
# is the chicken-and-egg seed; once this OIDC identity exists, CI uses it instead.

resource "infisical_identity" "github_actions" {
  name   = "github-actions-oidc"
  org_id = var.org_id

  # Org-level role is no-access on purpose: this identity draws its actual
  # permissions from the project membership below, never org-wide.
  role = "no-access"
}

resource "infisical_identity_oidc_auth" "github_actions" {
  identity_id = infisical_identity.github_actions.id

  # GitHub's OIDC provider. The discovery URL serves the JWKS Infisical uses to
  # verify the token signature; bound_issuer must equal the token's `iss` claim.
  oidc_discovery_url = "https://token.actions.githubusercontent.com"
  bound_issuer       = "https://token.actions.githubusercontent.com"

  # The `aud` GitHub stamps on the token. With no audience requested in the
  # workflow, GitHub defaults it to the repository-owner URL
  # (https://github.com/<org>); set var.github_oidc_audience to match whatever
  # the workflow requests.
  bound_audiences = [var.github_oidc_audience]

  # Scope trust to any workflow in this one repo (any branch / PR / tag),
  # mirroring the AWS root's repo:<org>/<repo>:* trust. bound_claims values may be
  # glob patterns — bound_subject is an exact match, which we don't want here.
  bound_claims = {
    sub = "repo:${var.github_org}/${var.github_repo}:*"
  }

  # Short-lived CI token — long enough for a job, no longer.
  access_token_ttl = var.access_token_ttl
}

# Grant the identity access to the Platform project so CI can read its secrets.
resource "infisical_project_identity" "github_actions" {
  project_id  = var.project_id
  identity_id = infisical_identity.github_actions.id

  roles = [
    {
      role_slug = var.project_role_slug
    },
  ]
}
