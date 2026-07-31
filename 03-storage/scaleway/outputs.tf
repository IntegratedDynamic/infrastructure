output "bucket_name" {
  description = "Provisioned backup bucket name."
  value       = module.buckets["backup"].bucket_name
}

output "bucket_region" {
  description = "Region the backup bucket was created in."
  value       = module.buckets["backup"].bucket_region
}

output "bucket_endpoint" {
  description = "S3-compatible endpoint URL for the backup bucket."
  value       = module.buckets["backup"].bucket_endpoint
}

output "workload_access_key" {
  description = "Public access key for the scoped Kubernetes backup workload identity. The secret key is in Infisical only."
  value       = module.buckets["backup"].access_key
}

output "workload_secret_key" {
  sensitive   = true
  description = "Public access key for the scoped Kubernetes backup workload identity. The secret key is in Infisical only."
  value       = module.buckets["backup"].secret_key
}

# ── Velero (separate bucket + identity) ──────────────────────────────────────

output "velero_bucket_name" {
  description = "Provisioned Velero backup bucket name."
  value       = module.buckets["velero"].bucket_name
}

output "velero_workload_access_key" {
  description = "Public access key for the scoped Velero Kubernetes workload identity."
  value       = module.buckets["velero"].access_key
}

output "velero_workload_secret_key" {
  sensitive   = true
  description = "Secret access key for the scoped Velero Kubernetes workload identity."
  value       = module.buckets["velero"].secret_key
}
