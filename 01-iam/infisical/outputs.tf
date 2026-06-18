# The identity ID is the principal GitHub Actions logs in as (the OIDC login call
# takes identityId). Public identifier — safe to surface and wire into CI.
output "identity_id" {
  description = "Infisical identity ID GitHub Actions authenticates as via OIDC."
  value       = infisical_identity.github_actions.id
}

output "oidc_auth_id" {
  description = "ID of the OIDC auth configuration attached to the identity."
  value       = infisical_identity_oidc_auth.github_actions.id
}
