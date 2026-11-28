# Read through terraform_remote_state by 10-cluster/scaleway (the in-cluster
# Secrets) and 11-secrets/openbao/managed (the copy kept in OpenBao).
output "access_key" {
  description = "Public access key of the external-dns identity."
  value       = module.external_dns.access_key
}

output "secret_key" {
  description = "Secret key of the external-dns identity."
  sensitive   = true
  value       = module.external_dns.secret_key
}
