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

output "workload_secret_key" {
  sensitive   = true
  description = "Public access key for the scoped Kubernetes backup workload identity. The secret key is in Infisical only."
  value       = scaleway_iam_api_key.kubernetes.secret_key
}

# ── OpenBao auto-unseal (AWS KMS, kms.tf) ────────────────────────────────────

output "openbao_unseal_kms_key_id" {
  description = "KMS key id for OpenBao's `seal \"awskms\"` stanza (kms_key_id)."
  value       = aws_kms_key.openbao_unseal.key_id
}

output "openbao_unseal_kms_key_arn" {
  description = "KMS key ARN of the OpenBao auto-unseal key."
  value       = aws_kms_key.openbao_unseal.arn
}

output "openbao_unseal_aws_region" {
  description = "AWS region the unseal key lives in (OpenBao seal `region`)."
  value       = var.aws_region
}

output "openbao_unseal_access_key_id" {
  description = "AWS access key id OpenBao uses to reach the unseal key (AWS_ACCESS_KEY_ID)."
  value       = aws_iam_access_key.openbao_unseal.id
}

output "openbao_unseal_secret_access_key" {
  description = "AWS secret access key OpenBao uses to reach the unseal key (AWS_SECRET_ACCESS_KEY). Feed into the OpenBao Secret."
  sensitive   = true
  value       = aws_iam_access_key.openbao_unseal.secret
}
