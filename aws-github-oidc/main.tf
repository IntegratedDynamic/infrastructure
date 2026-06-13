# Keyless GitHub-OIDC -> AWS for Terraform state access. GitHub Actions mints a
# short-lived OIDC token, AWS STS trades it for temporary credentials via this
# role — so NO static AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY ever lives in
# GitHub secrets for the S3 backend.
#
# This covers ONLY the AWS/S3 side. Scaleway resources (Kapsule, VPC) still use a
# static Scaleway API key (github-ci/), because Scaleway IAM is not an OIDC
# relying party — see README.md.

# OIDC identity provider for GitHub Actions. One per AWS account; this is the
# canonical GitHub OIDC issuer. The audience (sts.amazonaws.com) and GitHub's
# thumbprints are defaulted by the module.
module "iam_oidc_provider" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-oidc-provider"
  version = "6.6.1"

  url = "https://token.actions.githubusercontent.com"

  tags = {
    Terraform   = "true"
    Environment = "dev"
  }
}

# Role GitHub Actions assumes via OIDC. Trust is scoped to this repo only
# (repo:<org>/<repo>:* — the module prefixes "repo:" itself). S3 read access is
# account-wide for now (intentional; tighten to the state bucket later).
module "iam_role_github_oidc" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role"
  version = "6.6.1"

  name               = "github-actions-terraform"
  description        = "Assumed by GitHub Actions (${var.github_org}/${var.github_repo}) via OIDC for Terraform S3 state access."
  enable_github_oidc = true

  oidc_wildcard_subjects = ["${var.github_org}/${var.github_repo}:*"]

  policies = {
    S3ReadOnly = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
  }

  tags = {
    Terraform   = "true"
    Environment = "dev"
  }

  # The trust policy references the OIDC provider by ARN; it must exist first.
  depends_on = [module.iam_oidc_provider]
}
