# The homelab's live Scaleway Kapsule cluster (workspace 10-cluster-scaleway-staging).
#
# Costs real money (cluster + node pool + LB + block storage), so it is OPT-IN
# for `run --all`: from live/, `terragrunt run --all plan` skips it unless you
# pass `--feature cluster=true`. Running it directly from this directory always
# works.

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

# Ordering only: the root reads these three states through its own
# `terraform_remote_state` data sources (bucket/key from env/*.tfvars). Those
# are kept on purpose — the outputs they expose are `sensitive`, and a
# Terragrunt `dependency` -> `inputs` hand-over would drop that marking.
dependencies {
  paths = [
    "../../../dev/03-storage/scaleway",
    "../../../dev/02-encryption/aws",
    "../../../dev/01-iam/workload/scaleway",
  ]
}

feature "cluster" {
  default = false
}

exclude {
  if      = !feature.cluster.value
  actions = ["all_except_output"]
}
