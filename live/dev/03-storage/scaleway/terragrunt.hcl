include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

inputs = {
  # Embedded in every bucket identity's IAM application/policy name. Must stay
  # "03-storage-scaleway-dev": renaming it renames the live IAM resources.
  workspace_name = include.root.locals.workspace
}
