output "role_arn" {
  description = "ARN of the org-wide Terraform-state access role (R/W + lock; named `tf-state-access`). Anyone in the org assumes it with `aws sts assume-role`."
  value       = module.tf_state_access.arn
}
