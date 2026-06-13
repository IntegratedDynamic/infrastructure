# Keyless GitHub-OIDC -> AWS for Terraform state access. GitHub Actions mints a
# short-lived OIDC token, AWS STS trades it for temporary credentials via this
# role — so NO static AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY ever lives in
# GitHub secrets for the S3 backend.
#
# This covers ONLY the AWS/S3 side. Scaleway resources (Kapsule, VPC) still use a
# static Scaleway API key (terraform-ci/), because Scaleway IAM is not an OIDC
# relying party — see README.md.

# OIDC identity provider for GitHub Actions. One per AWS account; this is the
# canonical GitHub OIDC issuer + the STS audience. The thumbprints are GitHub's
# CA chain leaves; AWS no longer strictly verifies them for this issuer, but they
# are kept for compatibility. Idempotent: a single provider per account.
resource "aws_iam_openid_connect_provider" "github_actions" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1",
  "1c58a3a8518e8759bf075b76b750d4f2df264fcd"]
}

resource "aws_iam_role" "github_actions" {
  name               = "github-actions-terraform"
  description        = "Assumed by GitHub Actions (IntegratedDynamic/infrastructure) via OIDC for Terraform S3 state access."
  assume_role_policy = data.aws_iam_policy_document.github_actions_trust.json
}

# Trust policy — only workflows in this specific repo (any branch/PR/tag) may
# assume the role, and only with the sts.amazonaws.com audience.
data "aws_iam_policy_document" "github_actions_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github_actions.arn]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_org}/${var.github_repo}:*"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

# Least privilege: read/write/lock on exactly the Terraform state bucket, nothing
# else. ListBucket + GetBucketVersioning on the bucket; object R/W/D on its keys.
resource "aws_iam_role_policy" "github_actions_s3" {
  name   = "terraform-state-s3"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.github_actions_s3.json
}

data "aws_iam_policy_document" "github_actions_s3" {
  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketVersioning"]
    resources = [var.state_bucket_arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${var.state_bucket_arn}/*"]
  }
}
