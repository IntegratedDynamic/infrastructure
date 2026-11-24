# "GitHub" login source: lets members of a GitHub organization log in with their
# GitHub account, and maps their organization membership / team membership to
# the authentik groups declared in var.groups (the groups that decide which
# applications, and so which "My applications" tiles, a user gets).
#
# The OAuth App's Client ID/secret are EXTERNAL secrets (issued by GitHub):
# kv/apps/authentik/credentials, Terraform-owned in 11-secrets/openbao/managed,
# delivered here as TF_VAR_github_client_id/_secret by the Workspace. Until real
# values exist (empty, or the "REPLACE_ME" placeholder), nothing here is created.
#
# Callback URL registered on the OAuth App:
#   https://sso.<domain>/source/oauth/callback/github/    (slug below = github)
#
# Deliberately NOT done: linking a GitHub login to an existing local user by
# e-mail (user_matching_mode stays "identifier"): a new account per GitHub
# identity, never merged into another one. Users with no group get no access
# and no tile; restricting enrollment itself to org members is a possible
# follow-up (a policy on the enrollment flow).

locals {
  github_enabled = (
    var.github_client_id != "" && var.github_client_id != "REPLACE_ME" &&
    var.github_client_secret != "" && var.github_client_secret != "REPLACE_ME"
  )
}

data "authentik_flow" "source_authentication" {
  slug = "default-source-authentication"
}

data "authentik_flow" "source_enrollment" {
  slug = "default-source-enrollment"
}

# GitHub's profile response carries no organization data, so the membership and
# teams are fetched with the user's own token (scope read:org, set on the
# source). Returning `groups` makes authentik add the user to those groups;
# with group_matching_mode = name_link below they are linked BY NAME to the
# groups declared in var.groups instead of creating look-alike ones.
resource "authentik_property_mapping_source_oauth" "github_groups" {
  count = local.github_enabled ? 1 : 0

  name       = "GitHub: organization and teams to groups"
  expression = <<-EOT
    organization = ${jsonencode(var.github_org)}
    member_group = ${jsonencode(var.github_member_group)}
    team_groups = ${jsonencode(var.github_team_groups)}

    membership = client.do_request(
        "GET",
        f"https://api.github.com/user/memberships/orgs/{organization}",
        token=token,
    )
    if membership.status_code == 404:
        active = False
    else:
        membership.raise_for_status()
        active = membership.json().get("state") == "active"

    groups = []
    if active:
        groups.append(member_group)
        teams = client.do_request(
            "GET",
            "https://api.github.com/user/teams?per_page=100",
            token=token,
        )
        teams.raise_for_status()
        for team in teams.json():
            in_org = team["organization"]["login"].lower() == organization.lower()
            if in_org and team["slug"] in team_groups:
                groups.append(team_groups[team["slug"]])

    return {
        "attributes": {"github_org_membership": {"organization": organization, "active": active}},
        "groups": sorted(set(groups)),
    }
  EOT
}

resource "authentik_source_oauth" "github" {
  count = local.github_enabled ? 1 : 0

  name          = "GitHub"
  slug          = "github"
  provider_type = "github"

  consumer_key    = var.github_client_id
  consumer_secret = var.github_client_secret

  # read:org: needed to read organization membership and teams.
  additional_scopes = "read:org"

  authentication_flow = data.authentik_flow.source_authentication.id
  enrollment_flow     = data.authentik_flow.source_enrollment.id

  # One account per GitHub identity, never merged into an existing user.
  user_matching_mode = "identifier"
  # Link returned group names to the Terraform-declared groups by name.
  group_matching_mode = "name_link"

  property_mappings = [authentik_property_mapping_source_oauth.github_groups[0].id]
}

# (The login page itself -- which sources and the passkey link it offers -- is
# login.tf: it is shared by every way of signing in, not specific to GitHub.)

# Accounts created by a source's enrollment flow are "external" by default, and
# authentik does NOT let external users open the application dashboard (the
# "My applications" tile page, /if/user/): they get "Permission denied -- the
# interface is only accessible to internal users" (seen live right after the
# first GitHub login). The tile page is the point of this setup, so the stage
# that writes these users creates them as "internal". Internal users get the
# dashboard and their own settings; admin access still needs explicit
# permissions, which nobody gets from logging in, and what an app grants is
# decided by its group bindings, not by the type.
#
# Like the identification stage above, a default object imported and managed
# whole. create_users_as_inactive MUST be spelled out: the provider defaults it
# to true while authentik ships false, so leaving it unset would create every
# new GitHub user disabled.
data "authentik_stage" "source_enrollment_write" {
  name = "default-source-enrollment-write"
}

import {
  to = authentik_stage_user_write.source_enrollment
  id = data.authentik_stage.source_enrollment_write.id
}

resource "authentik_stage_user_write" "source_enrollment" {
  name = "default-source-enrollment-write"

  user_creation_mode       = "always_create"
  create_users_as_inactive = false
  user_type                = "internal"
  user_path_template       = ""
}
