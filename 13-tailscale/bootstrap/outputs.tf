# Neither output is sensitive -- a federated identity's client ID can't
# authenticate on its own (it also needs a real GitHub Actions OIDC token
# matching issuer/subject/audience, which only GitHub can mint), same
# reasoning this repo already applies to AWS_TERRAFORM_ROLE_ARN (a plain
# `vars.`, not `secrets.`). They reach GitHub as secrets only because
# secrets-sync can't write variables -- see README's "Wiring into GitHub
# Actions" section.
output "federated_identities" {
  description = "Per federated identity (keyed like var.federated_identities): client_id (TS_OAUTH_CLIENT_ID) and audience (TS_AUDIENCE) for .github/actions/debug-tailscale."
  value = {
    for k, v in tailscale_federated_identity.this : k => {
      client_id = v.id
      audience  = var.federated_identities[k].audience
    }
  }
}
