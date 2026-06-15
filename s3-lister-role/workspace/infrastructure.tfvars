# Workspace "infrastructure".
#
# The FILENAME names the terraform workspace (so state lands at
# s3-lister-role/infrastructure/terraform.tfstate, isolated from other roots).
# The CONTENTS are this workspace's variable values. Both are consumed by
# .github/actions/terraform — see that action and CLAUDE.md.

region    = "eu-west-3"
role_name = "s3-lister"

# Repo-scoped path + boundary required by the CI grant (aws-github-oidc/). Must
# match the grant's pins exactly or the apply is denied.
role_path                = "/tf-managed/IntegratedDynamic/infrastructure/"
permissions_boundary_arn = "arn:aws:iam::503577850357:policy/tf-managed-boundary"

# Anyone in this AWS Organization may assume the role.
org_id = "o-f9lb1e5es9"

# Any repo in this GitHub org may assume the role directly via OIDC web identity.
github_oidc_subjects = ["IntegratedDynamic/*"]
