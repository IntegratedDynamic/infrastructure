output "bucket_names" {
  description = "Map of root-module slug => provisioned bucket name."
  value       = { for k, m in module.state_buckets : k => m.bucket_name }
}

output "bucket_endpoints" {
  description = "Map of root-module slug => S3-compatible endpoint URL (path-style: https://s3.<region>.scw.cloud/<bucket>)."
  value       = { for k, m in module.state_buckets : k => m.bucket_endpoint }
}

output "access_keys" {
  description = "Map of root-module slug => public access key for its dedicated identity (null where create_identity = false). Consuming roots' backend config needs this (and the matching secret key) via -backend-config, not ambient AWS_* env vars — see README.md."
  value       = { for k, m in module.state_buckets : k => m.access_key }
}

output "secret_keys" {
  description = "Map of root-module slug => secret access key for its dedicated identity (null where create_identity = false)."
  sensitive   = true
  value       = { for k, m in module.state_buckets : k => m.secret_key }
}
