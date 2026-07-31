# Backward-compatible names — 05-secrets/openbao/managed's
# terraform_remote_state reads these two specifically for the external-dns
# identity. Don't repoint them at a different identity if you add one; use
# the generic maps below for new identities instead.
output "workload_access_key" {
  description = "Public access key for the external-dns workload identity."
  value       = module.identities["external-dns"].access_key
}

output "workload_secret_key" {
  description = "Secret key for the external-dns workload identity. Not pushed anywhere yet (terraform output) — copy into OpenBao by hand at apps/external-dns/scaleway-dns-credentials (see gitops apps/external-dns-init)."
  sensitive   = true
  value       = module.identities["external-dns"].secret_key
}

output "access_keys" {
  description = "Map of identity key => public access key, for every identity in var.identities."
  value       = { for k, m in module.identities : k => m.access_key }
}

output "secret_keys" {
  description = "Map of identity key => secret access key, for every identity in var.identities."
  sensitive   = true
  value       = { for k, m in module.identities : k => m.secret_key }
}
