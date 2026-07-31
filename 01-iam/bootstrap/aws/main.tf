# =============================================================================
# CI identity for 02-encryption/aws — a role scoped to exactly the two
# things that root creates: a KMS key (+ alias) and a single-purpose IAM user
# (+ access key) under the /openbao/ path. Full CRUD (including destroy) on
# both, since that root needs to be able to tear down what it creates — but
# nothing broader: no general IAM role/policy management, no capability to
# touch any resource outside the /openbao/ path. Also attaches the same
# state-bucket policy terraform-state-access uses, so this role can read/write
# its own Terraform backend state without a second, duplicated policy.
# =============================================================================

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# 00-foundation/aws's own state — read to attach the SAME state-bucket
# policy its terraform-state-access role uses, rather than duplicating the
# policy document or hardcoding its ARN.
data "terraform_remote_state" "remote_state_aws" {
  backend = "s3"
  config = {
    bucket = "id-terraform-state20260612164136440800000001"
    region = "eu-west-3"
    key    = "state-backend/00-remote-state-backend/terraform.tfstate"
  }
}

data "aws_iam_policy_document" "openbao_unseal_management" {
  statement {
    sid    = "KmsKeyAndAliasCrud"
    effect = "Allow"
    actions = [
      "kms:CreateKey",
      "kms:DescribeKey",
      "kms:PutKeyPolicy",
      "kms:GetKeyPolicy",
      "kms:TagResource",
      "kms:UntagResource",
      "kms:ListResourceTags",
      "kms:EnableKeyRotation",
      "kms:DisableKeyRotation",
      "kms:GetKeyRotationStatus",
      "kms:UpdateKeyDescription",
      "kms:ScheduleKeyDeletion",
      "kms:CancelKeyDeletion",
      "kms:CreateAlias",
      "kms:DeleteAlias",
      "kms:UpdateAlias",
      "kms:ListAliases",
    ]
    # KMS key IDs are randomly generated at creation time and can't be
    # resource-scoped in advance (CreateKey in particular has no resource-level
    # permission support) — scoped by capability (this is a KMS-management
    # role, nothing else) rather than by ARN.
    resources = ["*"]
  }

  statement {
    sid    = "IamUserAndAccessKeyCrudUnderOpenbaoPath"
    effect = "Allow"
    actions = [
      "iam:CreateUser",
      "iam:GetUser",
      "iam:DeleteUser",
      "iam:TagUser",
      "iam:UntagUser",
      "iam:CreateAccessKey",
      "iam:DeleteAccessKey",
      "iam:ListAccessKeys",
      "iam:UpdateAccessKey",
    ]
    resources = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:user/openbao/*"]
  }
}

module "openbao_unseal_policy" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-policy"
  version = "6.6.1"

  name        = "openbao-unseal-ci"
  path        = "/"
  description = "Full CRUD on the KMS key/alias + IAM user/access-key that 02-encryption/aws manages. Nothing else."
  policy      = data.aws_iam_policy_document.openbao_unseal_management.json

  tags = {
    Terraform   = "true"
    Environment = "dev"
  }
}

# Role GitHub Actions assumes via OIDC to apply 02-encryption/aws (and its
# own state). use_name_prefix = false keeps the name stable (no random
# suffix).
module "openbao_unseal_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role"
  version = "6.6.1"

  name               = "openbao-unseal-ci"
  use_name_prefix    = false
  description        = "Assumed by GitHub Actions (${var.github_org}/${var.github_repo}) via OIDC: manages the KMS key + IAM user for OpenBao's auto-unseal, plus its own Terraform state."
  enable_github_oidc = true

  oidc_wildcard_subjects = ["${var.github_org}/${var.github_repo}:*"]

  policies = {
    openbao-unseal         = module.openbao_unseal_policy.arn
    terraform-state-access = data.terraform_remote_state.remote_state_aws.outputs.terraform_state_access_policy_arn
  }

  tags = {
    Terraform   = "true"
    Environment = "dev"
  }
}
