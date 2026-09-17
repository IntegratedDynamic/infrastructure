# 13-tailscale/bootstrap: the Tailscale-side trust anchor for live GitHub
# Actions debugging (infra#110) -- a tailnet ACL granting SSH from this
# tailnet's own members to `tag:ci-debug` nodes, plus an OIDC workload
# identity federation trust that lets GitHub Actions itself join the
# tailnet directly with its own per-run OIDC token (see
# .github/actions/debug-tailscale) -- no static long-lived secret at all.
# Replaces the earlier upterm-based approach entirely -- see CLAUDE.md's
# "Live debugging via Tailscale SSH" section for the full picture.

locals {
  # Free-form and chosen by us (Tailscale's own auto-generated default isn't
  # readable back through this resource -- `audience` is Optional but NOT
  # Computed in the provider schema, so leaving it unset would drift). Must
  # match .github/actions/debug-tailscale's `audience` input exactly.
  ci_debug_audience = "tailscale-ci-debug"
}

# overwrite_existing_content = true means this REPLACES whatever ACL
# currently exists in the tailnet on first apply -- reconcile any
# manually-created policy into this resource's `acl` argument BEFORE the
# first apply, or existing rules will be lost. See README's "First apply"
# section.
resource "tailscale_acl" "this" {
  overwrite_existing_content = true

  acl = jsonencode({
    tagOwners = {
      # autogroup:admin (not autogroup:owner) so any tailnet admin -- not
      # just the account owner specifically -- can hand-tag a device too.
      "tag:ci-debug" = ["autogroup:admin"]
    }

    # Baseline "everything can talk to everything" between member devices
    # -- matches a fresh personal tailnet's own default policy, kept
    # explicit here since overwrite_existing_content replaces whatever was
    # there. A SEPARATE grant to tag:ci-debug is required too: tagged
    # devices are excluded from autogroup:member, and Tailscale computes
    # each node's netmap from these `acls` entries specifically -- the
    # `ssh` block below governs SSH auth on top, but grants no network
    # reachability by itself. Without this second rule a tag:ci-debug node
    # doesn't even appear as a peer (confirmed live 2026-09-17: 0 peers
    # visible despite a successful join).
    acls = [
      {
        action = "accept"
        src    = ["autogroup:member"]
        dst    = ["autogroup:member:*"]
      },
      {
        action = "accept"
        src    = ["autogroup:member"]
        dst    = ["tag:ci-debug:*"]
      },
    ]

    # The actual point of this root: any of this tailnet's own member
    # devices (the admin's machine, Claude's machine once joined) can SSH
    # into a tag:ci-debug node as any non-root local user -- real SSH exec
    # semantics, no ForceCommand trick, no shared pane.
    ssh = [
      {
        action = "accept"
        src    = ["autogroup:member"]
        dst    = ["tag:ci-debug"]
        users  = ["autogroup:nonroot"]
      },
    ]
  })
}

# GitHub Actions presents its own workflow-run OIDC token straight to
# Tailscale (permissions: id-token: write in the calling workflow); no
# authkey/OAuth-secret ever leaves this state or touches a GitHub secret.
# `subject` mirrors this repo's existing AWS OIDC trust scope
# (repo:IntegratedDynamic/infrastructure:*, see 00-foundation/aws's
# terraform-state-access role) -- repo-wide, any workflow/branch/event.
resource "tailscale_federated_identity" "ci_debug" {
  description = "GitHub Actions OIDC for infra110 CI debug"
  issuer      = "https://token.actions.githubusercontent.com"
  subject     = "repo:IntegratedDynamic/infrastructure:*"
  scopes      = ["auth_keys"]
  tags        = ["tag:ci-debug"]
  audience    = local.ci_debug_audience

  # The tag must exist (tagOwners) before a federated identity can be
  # scoped to assign it.
  depends_on = [tailscale_acl.this]
}
