output "bucket_name" {
  description = "Provisioned bucket name."
  value       = scaleway_object_bucket.this.name
}

output "bucket_region" {
  description = "Region the bucket was created in."
  value       = scaleway_object_bucket.this.region
}

output "bucket_endpoint" {
  description = "S3-compatible endpoint URL for the bucket."
  value       = "https://s3.${var.region}.scw.cloud/${var.bucket_name}"
}

output "access_key" {
  description = "Public access key for the scoped workload identity, or null when create_identity = false."
  value       = try(module.identity[0].access_key, null)
}

output "secret_key" {
  description = "Secret access key for the scoped workload identity, or null when create_identity = false."
  sensitive   = true
  value       = try(module.identity[0].secret_key, null)
}
