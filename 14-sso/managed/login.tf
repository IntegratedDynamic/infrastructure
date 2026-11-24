# The login page: which ways of signing in it offers.
#
# authentik's default identification stage is what renders the login page. It
# is one of authentik's default objects, so it is IMPORTED and managed whole,
# like the embedded outpost in main.tf, with every attribute spelled out as
# authentik ships it (a managed resource would otherwise reset the ones left
# unset). What differs from the shipped default is exactly the three lines
# marked below.
#
# Not done with a blueprint patching it: an inline authentik_blueprint created
# through the API is never applied by the worker (status stays "unknown", no
# apply_blueprint task, reproduced on kind) -- only an explicit
# POST .../managed/blueprints/<id>/apply/ runs it, which Terraform cannot do.
#
# Ways to sign in, all landing on the SAME authentik user:
#  - a login source (github.tf: org members; each source's own enrollment
#    policy decides whether a NEW account can be created through it);
#  - a passkey (passkey.tf), offered both as an autofill entry on the username
#    field and as a "passwordless" link at the bottom of the page.
# Which groups a user is in (so which apps and tiles they get) is the same
# whatever way they signed in.
data "authentik_stage" "identification" {
  name = "default-authentication-identification"
}

import {
  to = authentik_stage_identification.login
  id = data.authentik_stage.identification.id
}

resource "authentik_stage_identification" "login" {
  name = "default-authentication-identification"

  user_fields               = ["email", "username"]
  case_insensitive_matching = true
  show_matched_user         = true
  show_source_labels        = false
  pretend_user_exists       = true
  enable_remember_me        = false

  # differs from the shipped default: the sources shown on the page.
  sources = local.github_enabled ? [authentik_source_oauth.github[0].uuid] : []

  # differs from the shipped default: passkey sign-in (passkey.tf).
  # webauthn_stage is the VALIDATION stage (it checks the assertion made from
  # the username field's autofill), not the enrolment stage: pointing it at the
  # latter is rejected by the API ("Invalid pk ... object does not exist").
  passwordless_flow = authentik_flow.passkey_login.uuid
  webauthn_stage    = authentik_stage_authenticator_validate.passkey.id
}
