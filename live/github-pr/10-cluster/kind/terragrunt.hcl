# kind.yml's on-every-PR validation of the platform-apps DAG against a
# disposable kind cluster. Its state dies with the cluster, so this unit
# replaces the shared s3 backend with a local one (gitignored *.tfstate).
#
# Needs Docker + kind and a root-capable cloud-provider-kind, so opt-in for
# `run --all` (`--feature cluster=true`).

include "root" {
  path           = find_in_parent_folders("root.hcl")
  expose         = true
  merge_strategy = "deep"
}

remote_state {
  backend = "local"

  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }

  config = {
    path = "${get_terragrunt_dir()}/terraform.tfstate"
  }
}

# Ordering only (see ../../../staging/10-cluster/scaleway): the root reads these
# two states through its own terraform_remote_state data sources.
dependencies {
  paths = [
    "../../../dev/03-storage/scaleway",
    "../../../dev/02-encryption/aws",
  ]
}

terraform {
  extra_arguments "pr_head_ref" {
    commands = get_terraform_commands_that_need_vars()
    # infra_revision is the PR's own head ref, so a PR touching
    # 10-cluster/platform-apps is validated against ITS OWN changes, not main
    # (the entire point of this tier). Unset locally: auto-detects the branch.
    arguments = get_env("HEAD_REF", "") != "" ? ["-var", "infra_revision=${get_env("HEAD_REF")}"] : []
  }
}

feature "cluster" {
  default = false
}

exclude {
  if      = !feature.cluster.value
  actions = ["all_except_output"]
}
