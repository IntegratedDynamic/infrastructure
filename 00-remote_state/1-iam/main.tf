# An org-wide, read-only S3-lister IAM role — the first role created BY the CI
# rather than by a human. It is created/updated when a push to main touches this
# root (see .github/workflows/s3-lister-role.yml): GitHub Actions assumes the
# identity/00-ci-trust CI role and runs `terraform apply`.
#
# Two things are mandatory for the CI role to be ALLOWED to create this (see
# identity/00-ci-trust/iam-ci.tf): the role must sit under the managed `path` and
# carry the `permissions_boundary`. Omit either and the apply is denied.
#
# Trust: two doors, both org-scoped, that the module ORs together.
#   1. AWS principals in our AWS Organization — aws:PrincipalOrgID pins the org,
#      so any caller whose credentials already belong to `var.org_id` may assume
#      it (e.g. an SSO session, or a role assumed elsewhere in the org).
#   2. GitHub Actions in our GitHub org, DIRECTLY via OIDC web identity — no
#      routing through the bootstrap CI role. `enable_github_oidc` adds an
#      sts:AssumeRoleWithWebIdentity statement; `oidc_wildcard_subjects` scopes
#      the token `sub` to `repo:<org>/*` (the module prepends `repo:`). This is
#      the GitHub-org analogue of aws:PrincipalOrgID: any repo in the org, any
#      branch, can assume the role keylessly.
#
# `use_name_prefix = false` keeps the role name EXACTLY `var.role_name` (no random
# suffix) so its ARN is stable and a workflow can name it in configure-aws-credentials.
module "s3_lister" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role"
  version = "6.6.1"

  name            = var.role_name
  use_name_prefix = false
  path            = var.role_path
  description     = "Org-wide Terraform-state S3 access (read/write + lock). Created by CI; capped by the tf-managed permissions boundary."

  permissions_boundary = var.permissions_boundary_arn

  # Door 2: keyless GitHub-OIDC, org-wide. `var.github_oidc_subjects` are
  # org/repo globs; the module prepends `repo:` and matches the token `sub`.
  enable_github_oidc     = true
  oidc_wildcard_subjects = var.github_oidc_subjects

  # Door 1: AWS principals in our AWS Organization.
  trust_policy_permissions = {
    OrgWideAssume = {
      actions = ["sts:AssumeRole"]
      principals = [{
        type        = "AWS"
        identifiers = ["*"]
      }]
      condition = [{
        test     = "StringEquals"
        variable = "aws:PrincipalOrgID"
        values   = [var.org_id]
      }]
    }
  }
  
  policies = {
    S3FullAccess = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
  }

  tags = {
    Terraform   = "true"
    Environment = "dev"
    ManagedBy   = "ci"
  }
}
