output "bucket_name" {
  description = "State bucket name."
  value       = module.tfstate_bucket.s3_bucket_id
}

output "bucket_arn" {
  description = "State bucket ARN."
  value       = module.tfstate_bucket.s3_bucket_arn
}

output "region" {
  description = "State bucket region."
  value       = var.region
}
