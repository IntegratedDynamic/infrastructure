# Invitations: how someone with no GitHub account in the organization (any
# e-mail address) gets an account, already in a group.
#
# One enrollment flow per invitable group (var.invitation_groups), because the
# group is a property of the flow's user-write stage: choosing the flow when
# creating the invitation is choosing the group.
#
# The admin's part, in authentik: Directory > Invitations > create, pick the flow
# `invitation-<group>`, "single use" + an expiry, optionally pre-fill the e-mail
# (custom attributes: {"email": "someone@example.com"}), copy the link and send
# it (no mail server is configured):
#   https://sso.<domain>/if/flow/invitation-<group>/?itoken=<invitation>
# ALWAYS pick the flow: an invitation not tied to one is accepted by every
# invitation flow.
#
# The guest's part: username, name, e-mail, then a passkey (passkey.tf's own
# stage: no password exists anywhere), and they are signed in. Someone who
# leaves before the passkey step owns an account they cannot sign into: delete
# it in Directory > Users and invite them again.

resource "authentik_stage_invitation" "invitation" {
  name = "invitation"
  # Without a valid invitation token the flow stops here.
  continue_flow_without_invitation = false
}

resource "authentik_stage_prompt_field" "invitation" {
  for_each = {
    username = { label = "Username", type = "username", order = 10 }
    name     = { label = "Full name", type = "text", order = 20 }
    email    = { label = "E-mail", type = "email", order = 30 }
  }

  name      = "invitation-${each.key}"
  field_key = each.key
  label     = each.value.label
  type      = each.value.type
  order     = each.value.order
  required  = true
}

# authentik allows two users with the same e-mail address, and apps identify
# people by it (Firefly III signs in whoever carries the address it is sent).
# A guest must not be able to register an address that already has an account.
resource "authentik_policy_expression" "invitation_unique_email" {
  name       = "invitation-unique-email"
  expression = <<-EOT
    from authentik.core.models import User

    email = request.context.get("prompt_data", {}).get("email", "").strip()
    if User.objects.filter(email__iexact=email).exists():
        ak_message("This e-mail address already has an account.")
        return False
    return True
  EOT
}

resource "authentik_stage_prompt" "invitation" {
  name                = "invitation-profile"
  fields              = [for k in ["username", "name", "email"] : authentik_stage_prompt_field.invitation[k].id]
  validation_policies = [authentik_policy_expression.invitation_unique_email.id]
}

resource "authentik_stage_user_write" "invitation" {
  for_each = var.invitation_groups

  name                     = "invitation-write-${each.key}"
  user_creation_mode       = "always_create"
  create_users_as_inactive = false
  create_users_group       = authentik_group.groups[each.key].id
  # internal: external users are refused the "My applications" page (github.tf).
  user_type          = "internal"
  user_path_template = "users/invited"
}

resource "authentik_flow" "invitation" {
  for_each = var.invitation_groups

  name        = "Invitation: ${each.key}"
  title       = "Create your account"
  slug        = "invitation-${each.key}"
  designation = "enrollment"
  # A signed-in person opening an invitation link is not enrolled a second time.
  authentication = "require_unauthenticated"
}

locals {
  # Order of the stages in every invitation flow.
  invitation_stage_order = {
    invitation = 10
    profile    = 20
    write      = 30
    passkey    = 40
    login      = 50
  }

  invitation_bindings = {
    for pair in setproduct(var.invitation_groups, keys(local.invitation_stage_order)) :
    "${pair[0]}/${pair[1]}" => { group = pair[0], step = pair[1] }
  }
}

resource "authentik_flow_stage_binding" "invitation" {
  for_each = local.invitation_bindings

  target = authentik_flow.invitation[each.value.group].uuid
  order  = local.invitation_stage_order[each.value.step]
  stage = {
    invitation = authentik_stage_invitation.invitation.id
    profile    = authentik_stage_prompt.invitation.id
    write      = authentik_stage_user_write.invitation[each.value.group].id
    passkey    = authentik_stage_authenticator_webauthn.passkey.id
    login      = authentik_stage_user_login.passkey.id
  }[each.value.step]
  # The token is checked as soon as the flow is opened, not after the form.
  evaluate_on_plan     = true
  re_evaluate_policies = true
}
