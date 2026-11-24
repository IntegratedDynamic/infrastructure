# OIDC clients: the platform's own apps (ArgoCD, Grafana, Crossview, OpenBao...)
# that used to log in through Dex, now served by authentik (infra issue #135).
# One OAuth2/OpenID provider + one application per client, so each shows up on
# the "My applications" page of the groups allowed to use it.
#
# Issuer of each client: https://sso<host_suffix>.<domain>/application/o/<slug>/
# (slug = the key in var.oidc_clients); authorize/token/userinfo are shared:
# /application/o/authorize/, /application/o/token/, /application/o/userinfo/.
#
# The CLIENT SECRETS are not generated here: they are the SAME internal random
# secrets the Dex static clients used (now kv/apps/authentik/oidc-clients, owned by
# 11-secrets/openbao/managed), so every client keeps reading the secret it
# already reads and only its issuer changes. They reach this root as
# TF_VAR_oidc_client_secrets (one JSON map, key = client key).

locals {
  oidc_scope_mappings = [
    "goauthentik.io/providers/oauth2/scope-openid",
    "goauthentik.io/providers/oauth2/scope-email",
    "goauthentik.io/providers/oauth2/scope-profile",
  ]

  oidc_group_bindings = {
    for pair in flatten([
      for key, c in var.oidc_clients : [
        for g in c.groups : { key = "${key}/${g}", client = key, group = g }
      ]
    ]) : pair.key => pair
  }
}

# openid + email + profile. `profile` is also what carries the `groups` claim
# (group NAMES), so every client must request `profile`: there is no separate
# `groups` scope in authentik, an unknown scope is silently dropped.
data "authentik_property_mapping_provider_scope" "oidc" {
  managed_list = local.oidc_scope_mappings
}

# The default signing key authentik generates. Without a signing key id_tokens
# are signed with HS256 (the client secret) and a client verifying them through
# the JWKS endpoint (ArgoCD, Grafana...) cannot.
data "authentik_certificate_key_pair" "signing" {
  name = "authentik Self-signed Certificate"
}

resource "authentik_provider_oauth2" "oidc" {
  for_each = var.oidc_clients

  name      = each.value.name
  client_id = each.value.client_id

  client_type   = each.value.client_type
  client_secret = each.value.client_type == "confidential" ? lookup(var.oidc_client_secrets, each.key, null) : null

  authorization_flow = data.authentik_flow.authorization.id
  invalidation_flow  = data.authentik_flow.invalidation.id

  # Exact match only: a client may only ever be sent back to the URLs listed.
  # redirect_uri_type is what authentik fills in itself; written out so the
  # plan is empty (left out, every plan wanted to "update" it).
  allowed_redirect_uris = [
    for u in each.value.redirect_uris : {
      matching_mode     = "strict"
      url               = u
      redirect_uri_type = "authorization"
    }
  ]

  # MUST be set: a provider created through the API/Terraform has NO grant
  # types by default, and authentik then answers every authorize request with
  # invalid_request "The request is otherwise malformed" (seen live). The
  # authorization code flow, plus refresh tokens (offline_access / long
  # sessions); nothing else (no implicit, password or client_credentials).
  grant_types = ["authorization_code", "refresh_token"]

  property_mappings = data.authentik_property_mapping_provider_scope.oidc.ids
  signing_key       = data.authentik_certificate_key_pair.signing.id

  # Claims (incl. groups) in the id_token itself: ArgoCD reads groups from it.
  include_claims_in_id_token = true
  issuer_mode                = "per_provider"
}

resource "authentik_application" "oidc" {
  for_each = var.oidc_clients

  name              = each.value.name
  slug              = each.key
  group             = each.value.section
  protocol_provider = authentik_provider_oauth2.oidc[each.key].id
  meta_launch_url   = each.value.launch_url
  # A client with no UI of its own (the ArgoCD CLI) still needs an application:
  # its slug is part of the issuer. It just gets no tile.
  meta_hide = each.value.hide_tile
}

resource "authentik_policy_binding" "oidc_group" {
  for_each = local.oidc_group_bindings

  target = authentik_application.oidc[each.value.client].uuid
  group  = authentik_group.groups[each.value.group].id
  order  = 0
}
