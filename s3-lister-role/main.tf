# An org-wide, read-only S3-lister IAM role — the first role created BY the CI
# rather than by a human. It is created/updated when a push to main touches this
# root (see .github/workflows/s3-lister-role.yml): GitHub Actions assumes the
# aws-github-oidc CI role and runs `terraform apply`.
#
# Two things are mandatory for the CI role to be ALLOWED to create this (see
# aws-github-oidc/iam-ci.tf): the role must sit under the managed `path` and
# carry the `permissions_boundary`. Omit either and the apply is denied.
#
# Trust: assumable by ANY principal in our AWS Organization. We don't list
# account IDs — instead the trust condition pins aws:PrincipalOrgID, so every
# (and only) caller whose credentials belong to org `var.org_id` may assume it.
module "s3_lister" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role"
  version = "6.6.1"

  name        = var.role_name
  path        = var.role_path
  description = "Org-wide read-only S3 lister. Created by CI; capped by the tf-managed permissions boundary."

  permissions_boundary = var.permissions_boundary_arn

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

  # Same access the original GitHub Action had: list/read S3. The boundary clamps
  # it anyway, but S3 read is well within the ceiling.
  policies = {
    S3ReadOnly = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
  }

  tags = {
    Terraform   = "true"
    Environment = "dev"
    ManagedBy   = "ci"
  }
}
