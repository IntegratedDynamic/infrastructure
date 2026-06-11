output "application_id" {
  description = "IAM application ID backing the GitHub Actions CI identity."
  value       = scaleway_iam_application.github_ci.id
}

# The access key is a public identifier (like an AWS access key ID), so it's safe
# to surface. The secret half is never output — read it from Infisical or state.
output "access_key" {
  description = "SCW_ACCESS_KEY for the CI identity (public identifier)."
  value       = scaleway_iam_api_key.github_ci.access_key
}
