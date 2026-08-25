output "application_id" {
  description = "IAM application ID backing the GitHub Actions CI identity."
  value       = module.ci_identity.application_id
}

# The access key is a public identifier (like an AWS access key ID), so it's safe
# to surface.
output "access_key" {
  description = "SCW_ACCESS_KEY for the CI identity (public identifier)."
  value       = module.ci_identity.access_key
}

# Sensitive -- read by 11-secrets/openbao/managed to merge into
# kv/apps/secrets-sync/github/infrastructure-scaleway, so the real value can
# flow to GitHub via OpenBao+ESO instead of a manual `gh secret set` (see
# that root's README's "Wiring the GitHub secrets" section -- superseded by
# this for ongoing rotation, kept there for the very first bootstrap).
output "secret_key" {
  description = "SCW_SECRET_KEY for the CI identity."
  value       = module.ci_identity.secret_key
  sensitive   = true
}
