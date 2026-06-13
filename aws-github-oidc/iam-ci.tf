# =============================================================================
# CI role that can run `terraform apply` to CREATE IAM ROLES — without being
# able to escalate its own privileges.
#
# A role that holds iam:CreateRole + iam:AttachRolePolicy is effectively admin:
# nothing stops it from minting a role with AdministratorAccess and using it.
# We close the three classic escalation vectors:
#
#   1. Create a role more powerful than yourself  -> a PERMISSIONS BOUNDARY caps
#      every role the CI creates, so effective perms = intersection(attached
#      policies, boundary). Even AdministratorAccess on a child role is clamped.
#   2. iam:PassRole a powerful role to a service you control  -> PassRole is
#      scoped to the managed path only (where every role carries the boundary).
#   3. Weaken the guardrail itself (rewrite/detach the boundary)  -> explicit
#      Denies on the boundary policy ARN and on DeleteRolePermissionsBoundary.
#
# Design decisions (see also README.md / CLAUDE.md):
#   - Boundary philosophy: "admin minus a hardened deny-list" (pragmatic for a
#     homelab — workloads run freely, only escalation is blocked).
#   - CI grant: tight — S3 state R/W + bounded IAM under one path only.
#   - The CI role does NOT carry the boundary itself: the boundary Denies
#     PutRolePermissionsBoundary, but the CI role legitimately needs that action
#     to stamp the boundary onto its children. The CI role is constrained by its
#     own (tight) policy instead.
#   - All CI-managed roles/policies live under a repo-scoped path
#     (/tf-managed/<org>/<repo>/) so the CI's IAM actions can be ARN-scoped to
#     exactly that subtree — never your SSO roles, the boundary, or its own role.
# =============================================================================

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  # Repo-scoped path for every role/policy the CI manages. Mirrors
  # `${{ github.repository }}` (= "IntegratedDynamic/infrastructure"), so the CI
  # workflow can feed `TF_VAR_role_path=/tf-managed/${{ github.repository }}/`
  # and each managed role derives its path automatically. IAM paths are
  # case-sensitive and must match this pin exactly, or the boundary condition
  # rejects the apply.
  managed_path = "/tf-managed/${var.github_org}/${var.github_repo}/"

  # The boundary ARN is built from a *fixed* name (not a resource reference) on
  # purpose: the boundary policy denies edits to itself, which would otherwise
  # create a self-referential cycle in the graph.
  boundary_arn = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:policy/${var.boundary_name}"

  # ARN globs the CI may operate on — the managed path subtree only.
  managed_role_arns   = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role${local.managed_path}*"
  managed_policy_arns = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:policy${local.managed_path}*"
}

# -----------------------------------------------------------------------------
# Permissions boundary — the CEILING for every role the CI creates.
# "Admin minus deny-list": allow everything, then carve out the actions that
# would let a bounded role escalate or escape the boundary.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "boundary" {
  # Baseline: full access. The Denies below are what actually matter.
  statement {
    sid       = "AdminBaseline"
    effect    = "Allow"
    actions   = ["*"]
    resources = ["*"]
  }

  # No IAM users / long-lived credentials, and no tampering with ANY permissions
  # boundary. A child role carrying this boundary therefore cannot mint users,
  # hand out access keys, or strip/replace boundaries to climb out.
  statement {
    sid    = "DenyUsersAndBoundaryTampering"
    effect = "Deny"
    actions = [
      "iam:CreateUser",
      "iam:CreateLoginProfile",
      "iam:CreateAccessKey",
      "iam:UpdateLoginProfile",
      "iam:PutUserPolicy",
      "iam:AttachUserPolicy",
      "iam:PutRolePermissionsBoundary",
      "iam:DeleteRolePermissionsBoundary",
      "iam:PutUserPermissionsBoundary",
      "iam:DeleteUserPermissionsBoundary",
    ]
    resources = ["*"]
  }

  # Account-/org-level levers are off-limits to bounded workloads.
  statement {
    sid    = "DenyAccountAndOrg"
    effect = "Deny"
    actions = [
      "organizations:*",
      "account:*",
    ]
    resources = ["*"]
  }

  # The ceiling must not be editable by anything wearing it.
  statement {
    sid    = "DenyEditingTheBoundaryItself"
    effect = "Deny"
    actions = [
      "iam:CreatePolicyVersion",
      "iam:SetDefaultPolicyVersion",
      "iam:DeletePolicy",
      "iam:DeletePolicyVersion",
    ]
    resources = [local.boundary_arn]
  }
}

module "boundary_policy" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-policy"
  version = "6.6.1"

  name        = var.boundary_name
  path        = "/"
  description = "Permissions boundary capping every role the CI creates under ${local.managed_path}. Prevents privilege escalation."
  policy      = data.aws_iam_policy_document.boundary.json

  tags = {
    Terraform   = "true"
    Environment = "dev"
  }
}

# -----------------------------------------------------------------------------
# CI grant — what the GitHub OIDC role itself may do. Deliberately tight:
# S3 state R/W + bounded IAM management under the managed path only.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "ci" {
  # Terraform remote state: list + read/write/delete objects (the S3-native lock
  # is just an object, so Put/Delete covers locking). Scoped to the state bucket.
  statement {
    sid       = "TerraformStateBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketVersioning", "s3:GetBucketLocation"]
    resources = [var.state_bucket_arn]
  }
  statement {
    sid       = "TerraformStateObjects"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${var.state_bucket_arn}/*"]
  }

  # Read across IAM is needed for plan/refresh (reading current role/policy state)
  # and is not an escalation vector on its own.
  statement {
    sid       = "IamRead"
    effect    = "Allow"
    actions   = ["iam:Get*", "iam:List*"]
    resources = ["*"]
  }

  # Create/attach roles — but ONLY when the request stamps OUR boundary. This is
  # the core guardrail: the CI cannot create or extend a role that isn't capped.
  statement {
    sid    = "IamManageRolesRequireBoundary"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:AttachRolePolicy",
      "iam:PutRolePolicy",
      "iam:PutRolePermissionsBoundary",
    ]
    resources = [local.managed_role_arns]
    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [local.boundary_arn]
    }
  }

  # Lifecycle actions that don't take the boundary condition key. Note the
  # ABSENCE of iam:DeleteRolePermissionsBoundary: letting the CI strip a boundary
  # off a child it had attached AdministratorAccess to would be an escalation.
  statement {
    sid    = "IamManageRolesLifecycle"
    effect = "Allow"
    actions = [
      "iam:DeleteRole",
      "iam:DeleteRolePolicy",
      "iam:DetachRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:UpdateRole",
      "iam:UpdateRoleDescription",
      "iam:UpdateAssumeRolePolicy",
    ]
    resources = [local.managed_role_arns]
  }

  # Customer-managed policies the CI creates also live under the managed path.
  statement {
    sid    = "IamManagePolicies"
    effect = "Allow"
    actions = [
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:SetDefaultPolicyVersion",
      "iam:TagPolicy",
      "iam:UntagPolicy",
    ]
    resources = [local.managed_policy_arns]
  }

  # PassRole only for bounded roles under the managed path — so the CI can't pass
  # a pre-existing powerful role to a service it controls.
  statement {
    sid       = "PassManagedRolesOnly"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [local.managed_role_arns]
  }

  # Backstop Deny (defense in depth, independent of the path scoping above):
  # never edit the boundary policy itself.
  statement {
    sid    = "DenyTouchingBoundaryPolicy"
    effect = "Deny"
    actions = [
      "iam:CreatePolicyVersion",
      "iam:SetDefaultPolicyVersion",
      "iam:DeletePolicy",
      "iam:DeletePolicyVersion",
    ]
    resources = [local.boundary_arn]
  }

  # Backstop Deny: refuse to create/extend ANY role (even outside the path —
  # e.g. your SSO roles or the CI role itself) whose boundary isn't ours. For
  # CreateRole this checks the boundary in the request; for Attach/Put it checks
  # the target's existing boundary. A missing key fails StringEquals, so the
  # Deny fires and unboundaried principals stay untouchable.
  statement {
    sid    = "DenyUnlessOurBoundary"
    effect = "Deny"
    actions = [
      "iam:CreateRole",
      "iam:AttachRolePolicy",
      "iam:PutRolePolicy",
      "iam:PutRolePermissionsBoundary",
    ]
    resources = ["*"]
    condition {
      test     = "StringNotEquals"
      variable = "iam:PermissionsBoundary"
      values   = [local.boundary_arn]
    }
  }
}

module "ci_policy" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-policy"
  version = "6.6.1"

  name        = "tf-managed-ci"
  path        = "/"
  description = "Grant for the GitHub Actions CI role: Terraform state R/W + privilege-escalation-safe IAM management under ${local.managed_path}."
  policy      = data.aws_iam_policy_document.ci.json

  tags = {
    Terraform   = "true"
    Environment = "dev"
  }
}
