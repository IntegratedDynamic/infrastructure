output "access_keys" {
  description = "Map of identity key => public access key, for every identity in var.identities."
  value       = { for k, m in module.identities : k => m.access_key }
}

output "secret_keys" {
  description = "Map of identity key => secret access key, for every identity in var.identities."
  sensitive   = true
  value       = { for k, m in module.identities : k => m.secret_key }
}
