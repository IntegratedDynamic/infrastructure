output "workload_access_key" {
  description = "Public access key for the external-dns workload identity."
  value       = scaleway_iam_api_key.external_dns.access_key
}

output "workload_secret_key" {
  description = "Secret key for the external-dns workload identity. Not pushed anywhere yet (terraform output) — copy into OpenBao by hand at apps/external-dns/scaleway-dns-credentials (see gitops apps/external-dns-init)."
  sensitive   = true
  value       = scaleway_iam_api_key.external_dns.secret_key
}
