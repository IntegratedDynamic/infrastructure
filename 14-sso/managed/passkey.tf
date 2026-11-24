# Passkeys: sign in without GitHub (or any other source) on a device that can
# hold one (Touch ID / Windows Hello / Android / a phone through the QR code /
# a hardware key / a password manager).
#
# Two halves, both declared here:
#
#  1. ENROLMENT. A signed-in user adds a passkey from their own settings
#     ("MFA devices" > "Passkey"), which runs the configure flow below. The
#     stage requires a DISCOVERABLE credential (resident key): that is what lets
#     the device offer the account by itself, so no username has to be typed,
#     and it requires user verification (biometric or PIN on the device), so
#     one passkey is "something you have + something you are" on its own.
#     authentik ships a default WebAuthn setup stage too; it asks for neither
#     ("preferred"), so it is left alone and this stricter one is added next to it.
#
#  2. SIGN-IN. A flow that is nothing but "prove you hold a passkey" then
#     "log in". It is linked at the bottom of the login page (the identification
#     stage's passwordless_flow) and the same passkeys are offered as autofill
#     on the username field (its webauthn_stage), see login.tf.
#
# A passkey belongs to an EXISTING user: this adds a way to sign in, not a way
# to create an account. First sign-in is still through a source (github.tf) or
# an account an admin created.
#
# A passkey is bound to the hostname it was created on (the WebAuthn "RP ID" is
# sso.<domain>), so changing the domain makes existing passkeys unusable: users
# add a new one. Nothing to migrate, but worth knowing before renaming the domain.

# --- enrolment ---------------------------------------------------------

resource "authentik_flow" "passkey_setup" {
  name        = "Add a passkey"
  title       = "Add a passkey"
  slug        = "passkey-setup"
  designation = "stage_configuration"
  # Only an authenticated user adds a device to THEIR OWN account.
  authentication = "require_authenticated"
}

resource "authentik_stage_authenticator_webauthn" "passkey" {
  name          = "passkey-setup"
  friendly_name = "Passkey"

  resident_key_requirement = "required"
  user_verification        = "required"

  # Makes the stage show up in the user's settings.
  configure_flow = authentik_flow.passkey_setup.uuid
}

resource "authentik_flow_stage_binding" "passkey_setup" {
  target = authentik_flow.passkey_setup.uuid
  stage  = authentik_stage_authenticator_webauthn.passkey.id
  order  = 0
}

# --- sign-in -----------------------------------------------------------

resource "authentik_flow" "passkey_login" {
  name        = "Sign in with a passkey"
  title       = "Sign in with a passkey"
  slug        = "passkey-authentication"
  designation = "authentication"
  # Same as authentik's default authentication flow.
  authentication = "none"
}

# No user is known when this stage runs: with a discoverable credential, the
# passkey itself says which account it is. webauthn only, and user verification
# enforced, so this one factor is not weaker than password + second factor.
# not_configured_action = "deny": someone who has no passkey cannot get past it.
resource "authentik_stage_authenticator_validate" "passkey" {
  name = "passkey-validation"

  device_classes             = ["webauthn"]
  webauthn_user_verification = "required"
  not_configured_action      = "deny"
}

# Every attribute spelled out as authentik's own default login stages have it
# (session ends with the browser; no network or geo binding), so a passkey
# session behaves exactly like a GitHub one.
resource "authentik_stage_user_login" "passkey" {
  name = "passkey-login"

  session_duration         = "seconds=0"
  remember_me_offset       = "seconds=0"
  remember_device          = "days=30"
  network_binding          = "no_binding"
  geoip_binding            = "no_binding"
  terminate_other_sessions = false
}

resource "authentik_flow_stage_binding" "passkey_validation" {
  target = authentik_flow.passkey_login.uuid
  stage  = authentik_stage_authenticator_validate.passkey.id
  order  = 10
}

resource "authentik_flow_stage_binding" "passkey_login" {
  target = authentik_flow.passkey_login.uuid
  stage  = authentik_stage_user_login.passkey.id
  order  = 100
}
