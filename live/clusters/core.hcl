# Included by the units of a cluster that runs on a core platform. Which core is
# said in one place only: `core` in the cluster's cluster.hcl. From it come the
# run order and the core states the cluster root reads.

locals {
  # Example values for live/clusters/staging/10-cluster/scaleway.
  core     = read_terragrunt_config(find_in_parent_folders("cluster.hcl")).locals.core # "main"
  core_dir = "${get_repo_root()}/live/core/${local.core}"                              # "<repo>/live/core/main"
}

# Ordering only: the root reads these states through its own
# `terraform_remote_state` data sources, because their outputs are `sensitive`
# and a Terragrunt `dependency` -> `inputs` hand-over would drop that marking.
dependencies {
  paths = [
    "${local.core_dir}/03-storage/scaleway",
    "${local.core_dir}/02-encryption/aws",
    "${local.core_dir}/01-iam/workload/scaleway",
  ]
}

inputs = {
  backup_scaleway_state_bucket    = "id-terraform-state-03-storage-scaleway"
  backup_scaleway_state_key       = "03-storage/scaleway/${local.core}/terraform.tfstate"
  openbao_unseal_aws_state_bucket = "id-terraform-state-02-encryption-aws"
  openbao_unseal_aws_state_key    = "02-encryption/aws/${local.core}/terraform.tfstate"
  dns_scaleway_state_bucket       = "id-terraform-state-01-iam-workload-scaleway"
  dns_scaleway_state_key          = "01-iam/workload/scaleway/${local.core}/terraform.tfstate"
}
