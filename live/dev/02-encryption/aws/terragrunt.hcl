include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

inputs = {
  # Embedded in resource names: renaming it renames live resources.
  # Must stay "02-encryption-aws-dev".
  workspace_name = include.root.locals.workspace
}
