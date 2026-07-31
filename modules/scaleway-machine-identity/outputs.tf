output "application_id" {
  description = "IAM application ID backing this machine identity."
  value       = scaleway_iam_application.this.id
}

output "access_key" {
  description = "Public access key identifier for the generated API key."
  value       = scaleway_iam_api_key.this.access_key
}

output "secret_key" {
  description = "Secret access key for the generated API key."
  sensitive   = true
  value       = scaleway_iam_api_key.this.secret_key
}

output "policy_ids" {
  description = "Map of policy-purpose slug => scaleway_iam_policy ID."
  value       = { for k, p in scaleway_iam_policy.this : k => p.id }
}
