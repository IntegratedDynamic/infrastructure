# What the cluster needs to manage DNS: one Scaleway identity limited to DNS zone
# records, used inside the cluster by external-dns and cert-manager's DNS01
# webhook. No DNS zone or record is Terraform-managed here.
module "external_dns" {
  source = "../../modules/scaleway-machine-identity"

  application_name        = "external-dns-${var.workspace_name}"
  application_description = "Kubernetes workload identity for external-dns (${var.workspace_name}) — manages DNS zone records for domains bought through Scaleway."

  policies = {
    default = {
      name        = "external-dns-${var.workspace_name}"
      description = "DNS zone record read/write for the external-dns workload. No domain registration/transfer access."
      rules = [
        {
          # The project scalepack.fr's zone lives in.
          project_ids          = [var.project_id]
          permission_set_names = ["DomainsDNSFullAccess"]
        }
      ]
    }
  }

  project_id            = var.project_id
  api_key_description   = "external-dns workload credentials (${var.workspace_name})."
  api_key_rotation_days = var.api_key_rotation_days
}
