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
  description = "Public access key for the scoped workload identity."
  value       = module.identity.access_key
}

output "secret_key" {
  description = "Secret access key for the scoped workload identity."
  sensitive   = true
  value       = module.identity.secret_key
}
