output "bucket_name" {
  description = "Provisioned backup bucket name."
  value       = scaleway_object_bucket.backup.name
}

output "bucket_region" {
  description = "Region the backup bucket was created in."
  value       = scaleway_object_bucket.backup.region
}

output "bucket_endpoint" {
  description = "S3-compatible endpoint URL for the backup bucket."
  value       = "https://s3.${var.region}.scw.cloud/${var.bucket_name}"
}

output "workload_access_key" {
  description = "Public access key for the scoped Kubernetes backup workload identity. The secret key is in Infisical only."
  value       = scaleway_iam_api_key.kubernetes.access_key
}
