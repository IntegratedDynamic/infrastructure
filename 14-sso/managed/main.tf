# authentik-as-code: groups, forward-auth applications (proxy provider +
# application + group bindings) and the embedded outpost that serves them.
# Applied unattended by the authentik-managed Crossplane Workspace. Users and
# their group membership are deliberately NOT declared here.
#
# Validated end to end on kind first (spike behind infra issue #135): outpost
# + Envoy Gateway extAuth, per-app group access, per-user tiles.

locals {
  public_url = "https://sso${var.host_suffix}.${var.domain}"

  # One binding per (application, allowed group) pair.
  app_group_bindings = {
    for pair in flatten([
      for app_key, app in var.applications : [
        for g in app.groups : { key = "${app_key}/${g}", app = app_key, group = g }
      ]
    ]) : pair.key => pair
  }
}

# Flows authentik ships by default (blueprints); referenced by slug.
data "authentik_flow" "authorization" {
  slug = "default-provider-authorization-implicit-consent"
}

data "authentik_flow" "invalidation" {
  slug = "default-provider-invalidation-flow"
}

resource "authentik_group" "groups" {
  for_each = var.groups
  name     = each.key
}

resource "authentik_provider_proxy" "app" {
  for_each = var.applications

  name = each.value.name
  # "single application" forward auth: this provider only covers its own
  # external_host, so each application keeps an independent access policy
  # (domain-level mode would collapse every app under one cookie domain into
  # one application's bindings).
  mode               = "forward_single"
  external_host      = "https://${each.value.host_prefix}${var.host_suffix}.${var.domain}"
  authorization_flow = data.authentik_flow.authorization.id
  invalidation_flow  = data.authentik_flow.invalidation.id
}

resource "authentik_application" "app" {
  for_each = var.applications

  name              = each.value.name
  slug              = each.key
  group             = each.value.section
  protocol_provider = authentik_provider_proxy.app[each.key].id
  meta_launch_url   = "https://${each.value.host_prefix}${var.host_suffix}.${var.domain}"
}

resource "authentik_policy_binding" "app_group" {
  for_each = local.app_group_bindings

  target = authentik_application.app[each.value.app].uuid
  group  = authentik_group.groups[each.value.group].id
  order  = 0
}

# The embedded outpost ships with authentik (it is the forward-auth endpoint
# Envoy Gateway's extAuth calls). It is IMPORTED and managed as ONE resource on
# purpose: the per-provider authentik_outpost_provider_attachment resource is a
# read-modify-write of the outpost's provider list, so several of them created
# in parallel overwrite each other and leave only one provider attached
# (reproduced on kind). Owning the whole list here is atomic.
#
# `authentik_host` is the URL the outpost builds its login redirect from; left
# empty it falls back to "http://localhost/" and every redirect to the login
# flow breaks (seen live on the staging cluster, where setting only
# `authentik_host_browser` still redirected to localhost). `authentik_host_browser`
# is kept alongside it for the browser-facing URLs.
data "authentik_outpost" "embedded" {
  name = "authentik Embedded Outpost"
}

import {
  to = authentik_outpost.embedded
  id = data.authentik_outpost.embedded.id
}

resource "authentik_outpost" "embedded" {
  name               = "authentik Embedded Outpost"
  type               = "proxy"
  service_connection = null
  protocol_providers = [for p in authentik_provider_proxy.app : p.id]
  config = jsonencode({
    authentik_host         = local.public_url
    authentik_host_browser = local.public_url
  })
}
