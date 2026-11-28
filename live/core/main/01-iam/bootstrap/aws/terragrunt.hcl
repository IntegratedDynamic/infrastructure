include "root" {
  path = find_in_parent_folders("root.hcl")
}

dependency "foundation" {
  config_path = "../../../00-foundation/aws"
}

inputs = {
  state_access_policy_arn = dependency.foundation.outputs.terraform_state_access_policy_arn
}
