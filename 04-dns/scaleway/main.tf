# IAM identity for external-dns (gitops: platform/scaleway/external-dns.yml),
# scoped to Domains & DNS zone record management only — it can read/write DNS
# records, nothing else (no domain registration/transfer, no other product).
#
# scalepack.fr was bought directly through Scaleway Domains & DNS, so its zone
# already lives in the project this key is scoped to.
resource "scaleway_iam_application" "external_dns" {
  name        = "external-dns-${terraform.workspace}"
  description = "Kubernetes workload identity for external-dns (${terraform.workspace}) — manages DNS zone records for domains bought through Scaleway."
}

resource "scaleway_iam_policy" "external_dns" {
  name           = "external-dns-${terraform.workspace}"
  description    = "DNS zone record read/write for the external-dns workload. No domain registration/transfer access."
  application_id = scaleway_iam_application.external_dns.id

  rule {
    project_ids          = [var.project_id]
    permission_set_names = ["DomainsDNSFullAccess"]
  }
}

# Scaleway requires every API key to carry an expiry. time_rotating keeps the
# expiry self-renewing: once the window elapses, the next apply rotates the
# key — re-copy it into OpenBao by hand afterward (no automated push yet, see
# gitops apps/external-dns-init).
resource "time_rotating" "external_dns_key" {
  rotation_days = var.api_key_rotation_days
}

resource "scaleway_iam_api_key" "external_dns" {
  application_id     = scaleway_iam_application.external_dns.id
  description        = "external-dns workload credentials (${terraform.workspace})."
  default_project_id = var.project_id
  expires_at         = time_rotating.external_dns_key.rotation_rfc3339
}
