# The homelab's live Scaleway Kapsule cluster.
#
# Costs real money (cluster + node pool + LB + block storage), so it is OPT-IN
# for `run --all`: from live/, `terragrunt run --all plan` skips it unless you
# pass `--feature cluster=true`. Running it directly from this directory always
# works.

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

include "core" {
  path = find_in_parent_folders("core.hcl")
}

include "type" {
  path = "${get_repo_root()}/live/types/main.hcl"
}

# This cluster's own identity. Changing it replaces the live cluster.
inputs = {
  cluster_name = "scaleway-homelab"
}

feature "cluster" {
  default = false
}

exclude {
  if      = !feature.cluster.value
  actions = ["all_except_output"]
}
