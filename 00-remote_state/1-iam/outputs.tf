output "role_arn" {
  description = "ARN of the org-wide S3-lister role. Anyone in the org assumes it with `aws sts assume-role`."
  value       = module.s3_lister.arn
}
