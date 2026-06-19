# The identity ID is the principal GitHub Actions logs in as (the OIDC login call
# takes identityId). Public identifier — safe to surface and wire into CI.
output "github" {
  description = "Infisical identity ID GitHub Actions authenticates as via OIDC."
  value       = {
    identity_id = infisical_identity.github_actions.id
    identity_auth_id = infisical_identity_oidc_auth.github_actions.id
  }
}

output "kubernetes" {
  description = "Infisical identity ID for Kubernetes ESO."
  value       = {
    identity_id = infisical_identity.kubernetes.id
    identity_auth_id = infisical_identity_universal_auth.kubernetes.id
  }
}
