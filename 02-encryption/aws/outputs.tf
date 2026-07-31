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
