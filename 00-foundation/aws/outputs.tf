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

output "terraform_state_access_role_arn" {
  description = "ARN of the role every GitHub Actions workflow in this repo assumes via OIDC for Terraform state R/W (set as vars.AWS_TERRAFORM_ROLE_ARN)."
  value       = module.terraform_state_access_role.arn
}

output "terraform_state_access_policy_arn" {
  description = "ARN of the state-bucket R/W policy attached to terraform-state-access. Other roles that also need to read/write this bucket (e.g. for their own Terraform backend) attach this same policy instead of duplicating its statements — see 01-iam/bootstrap/aws."
  value       = module.terraform_state_access_policy.arn
}
