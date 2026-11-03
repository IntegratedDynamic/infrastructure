# 13-tailscale/bootstrap: the Tailscale-side trust anchor for live GitHub
# Actions debugging (infra#110) -- a tailnet ACL granting SSH from this
# tailnet's own members to `tag:ci-debug` nodes, plus an OIDC workload
# identity federation trust that lets GitHub Actions itself join the
# tailnet directly with its own per-run OIDC token (see
# .github/actions/debug-tailscale) -- no static long-lived secret at all.
# Replaces the earlier upterm-based approach entirely -- see CLAUDE.md's
# "Live debugging via Tailscale SSH" section for the full picture.

locals {
  # Every tag any identity assigns must exist in tagOwners before a
  # federated identity can be scoped to it.
  all_tags = distinct(flatten([for v in values(var.federated_identities) : v.tags]))
  # Tags whose nodes tailnet members may reach + SSH into.
  ssh_tags = distinct(flatten([for v in values(var.federated_identities) : v.tags if v.member_ssh]))

  # Built-in Tailscale ACL groups -- fixed by Tailscale itself, not
  # configurable.
  # autogroup:admin (not autogroup:owner) so any tailnet admin -- not just
  # the account owner specifically -- can hand-tag a device too.
  tag_owners   = ["autogroup:admin"]
  members      = ["autogroup:member"]
  ssh_users    = ["autogroup:nonroot"]
  members_dest = ["autogroup:member:*"]
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
      for tag in local.all_tags : tag => local.tag_owners
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
        src    = local.members
        dst    = local.members_dest
      },
      {
        action = "accept"
        src    = local.members
        dst    = [for tag in local.ssh_tags : "${tag}:*"]
      },
    ]

    # The actual point of this root: any of this tailnet's own member
    # devices (the admin's machine, Claude's machine once joined) can SSH
    # into a tag:ci-debug node as any non-root local user -- real SSH exec
    # semantics, no ForceCommand trick, no shared pane.
    ssh = [
      {
        action = "accept"
        src    = local.members
        dst    = local.ssh_tags
        users  = local.ssh_users
      },
    ]
  })
}

# Federated identities: the caller (e.g. GitHub Actions, see
# .github/actions/debug-tailscale) presents its own OIDC token straight to
# Tailscale; no authkey/OAuth-secret ever leaves this state or touches a
# GitHub secret. See var.federated_identities.
resource "tailscale_federated_identity" "this" {
  for_each = var.federated_identities

  description = each.value.description
  issuer      = each.value.issuer
  subject     = each.value.subject
  scopes      = each.value.scopes
  tags        = each.value.tags
  audience    = each.value.audience

  # The tags must exist (tagOwners) before a federated identity can be
  # scoped to assign them.
  depends_on = [tailscale_acl.this]
}
