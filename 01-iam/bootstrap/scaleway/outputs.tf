output "application_id" {
  description = "IAM application ID backing the GitHub Actions CI identity."
  value       = module.ci_identity.application_id
}

# The access key is a public identifier (like an AWS access key ID), so it's safe
# to surface. The secret half is never output — set it in GitHub Actions secrets
# by hand (see README).
output "access_key" {
  description = "SCW_ACCESS_KEY for the CI identity (public identifier)."
  value       = module.ci_identity.access_key
}
