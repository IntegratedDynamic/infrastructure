# Neither output is sensitive -- a federated identity's client ID can't
# authenticate on its own (it also needs a real GitHub Actions OIDC token
# matching issuer/subject/audience, which only GitHub can mint), same
# reasoning this repo already applies to AWS_TERRAFORM_ROLE_ARN (a plain
# `vars.`, not `secrets.`). Feed both into repo variables, not secrets --
# see README's "Wiring the GitHub repo variables" section.
output "ci_debug_oauth_client_id" {
  description = "TS_OAUTH_CLIENT_ID for .github/actions/debug-tailscale."
  value       = tailscale_federated_identity.ci_debug.id
}

output "ci_debug_audience" {
  description = "TS_AUDIENCE for .github/actions/debug-tailscale -- must match what the federated identity itself is scoped to."
  value       = local.ci_debug_audience
}
