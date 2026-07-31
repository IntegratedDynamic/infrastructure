output "role_arn" {
  description = "ARN of the openbao-unseal-ci role — set as the aws-role-arn input for any workflow that applies 02-encryption/aws."
  value       = module.openbao_unseal_role.arn
}
