output "role_id" {
  description = "AppRole role_id for the terraform identity (public identifier)."
  value       = vault_approle_auth_backend_role.terraform.role_id
}

output "secret_id" {
  description = "AppRole secret_id (sensitive). Read via `terraform output -raw secret_id` — don't paste into shell history."
  value       = vault_approle_auth_backend_role_secret_id.terraform.secret_id
  sensitive   = true
}
