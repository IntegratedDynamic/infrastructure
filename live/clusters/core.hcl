# Included by the units of a cluster that runs on a core platform. Which core is
# said in one place only: `core` in the cluster's cluster.hcl. From it come the
# core units the cluster depends on, whose outputs become its variables, and the
# core's wiring.hcl.
#
# Terragrunt reads those outputs from the core states (AWS_ACCESS_KEY_ID /
# AWS_SECRET_ACCESS_KEY), so a core unit must have been applied first. The roots
# declare the matching variables and keep only the attributes they use.

locals {
  # Example values for live/clusters/staging/10-cluster/scaleway.
  core     = read_terragrunt_config(find_in_parent_folders("cluster.hcl")).locals.core # "main"
  core_dir = "${get_repo_root()}/live/core/${local.core}"                              # "<repo>/live/core/main"
}

dependency "storage" {
  config_path = "${local.core_dir}/03-storage/scaleway"
}

dependency "unseal" {
  config_path = "${local.core_dir}/02-encryption/aws"
}

dependency "dns" {
  config_path = "${local.core_dir}/05-dns/scaleway"
}

inputs = merge(read_terragrunt_config("${local.core_dir}/wiring.hcl").inputs, {
  core_storage = dependency.storage.outputs
  core_unseal  = dependency.unseal.outputs
  core_dns     = dependency.dns.outputs
})
