# Non-bucket Scaleway workload identities — one Scaleway machine identity per
# entry in var.identities (see variables.tf), no owned bucket, no CI trust
# anchor. DNS credentials live in their own domain, 05-dns/scaleway. Add a
# future workload identity by adding a map entry, no new .tf resources.
module "identities" {
  source   = "../../../modules/scaleway-machine-identity"
  for_each = var.identities

  application_name        = "${each.key}-${var.workspace_name}"
  application_description = "Kubernetes workload identity for ${each.key} (${var.workspace_name}) — ${each.value.purpose}."

  policies = {
    default = {
      name        = "${each.key}-${var.workspace_name}"
      description = each.value.policy_description
      rules       = each.value.rules
    }
  }

  project_id            = var.project_id
  api_key_description   = "${each.key} workload credentials (${var.workspace_name})."
  api_key_rotation_days = each.value.api_key_rotation_days
}
