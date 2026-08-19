# Non-bucket Scaleway workload identities — one Scaleway machine identity per
# entry in var.identities (see variables.tf), no owned bucket, no CI trust
# anchor. external-dns today (DNS zone record management only, no DNS zone
# resource is Terraform-managed here). Add a future workload identity by
# adding a map entry, no new .tf resources.
module "identities" {
  source   = "../../../modules/scaleway-machine-identity"
  for_each = var.identities

  application_name        = "${each.key}-${terraform.workspace}"
  application_description = "Kubernetes workload identity for ${each.key} (${terraform.workspace}) — ${each.value.purpose}."

  policies = {
    default = {
      name        = "${each.key}-${terraform.workspace}"
      description = each.value.policy_description
      rules       = each.value.rules
    }
  }

  project_id            = var.project_id
  api_key_description   = "${each.key} workload credentials (${terraform.workspace})."
  api_key_rotation_days = each.value.api_key_rotation_days
}
