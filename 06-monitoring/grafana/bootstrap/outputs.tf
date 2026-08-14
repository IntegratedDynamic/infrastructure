output "service_account_id" {
  description = "Grafana service account ID for the terraform identity (public identifier)."
  value       = grafana_service_account.terraform.id
}

output "service_account_token" {
  description = "Grafana service account token (sensitive). Read via `terraform output -raw service_account_token` — don't paste into shell history."
  value       = grafana_service_account_token.terraform.key
  sensitive   = true
}
