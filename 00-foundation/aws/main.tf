# Holds the Terraform remote state for the whole org (see README.md).
# Uses the community terraform-aws-modules/s3-bucket module.
module "tfstate_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 5.0"

  bucket_prefix = var.bucket_prefix

  # Recover a corrupt/truncated state push by rolling back to a prior version.
  versioning = {
    enabled = true
  }

  # Encrypt every object at rest (SSE-S3, AES256 — no KMS key to manage).
  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm = "AES256"
      }
    }
  }

  # ACLs disabled, bucket owner owns everything — the modern replacement for a
  # `private` ACL. Combined with the public-access block below, the bucket and
  # its objects are unreachable anonymously (state can hold sensitive values).
  control_object_ownership = true
  object_ownership         = "BucketOwnerEnforced"

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  # Reject any non-TLS request to the state — defence in depth for secrets.
  attach_deny_insecure_transport_policy = true

  # Guard against accidentally deleting everyone's state: force_destroy stays
  # off, so `terraform destroy` fails while objects remain.
  force_destroy = false

  lifecycle_rule = [
    {
      id     = "expire-noncurrent-state-versions"
      status = "Enabled"

      # Empty filter == applies to the whole bucket.
      filter = {}

      # Only noncurrent (superseded) versions expire; the current state is kept.
      noncurrent_version_expiration = {
        days = var.noncurrent_version_expiration_days
      }
    }
  ]

  tags = {
    purpose   = "terraform-remote-state"
    terraform = "true"
  }
}

# =============================================================================
# CI's AWS access — keyless GitHub-OIDC, scoped to exactly this repo, with a
# policy that grants only S3 read/write on the state bucket above. Replaces
# the former 01-iam/bootstrap/aws + 01-iam/ci-managed/aws-state-access roots'
# much larger "CI can safely mint further IAM roles" system (a permissions
# boundary + a policy letting the CI role create/attach other roles under a
# managed path) — that system's only actual consumer was minting the one
# role that does state R/W. Once the role's own job is narrowed to exactly
# that, there's no IAM-management capability left to guard against
# escalating, so the guardrail system is gone along with it.
# =============================================================================

# OIDC identity provider for GitHub Actions. One per AWS account; this is the
# canonical GitHub OIDC issuer. The audience (sts.amazonaws.com) and GitHub's
# thumbprints are defaulted/dynamically-fetched by the module.
module "iam_oidc_provider" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-oidc-provider"
  version = "6.6.1"

  url = "https://token.actions.githubusercontent.com"

  tags = {
    Terraform   = "true"
    Environment = "dev"
  }
}

module "terraform_state_access_policy" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-policy"
  version = "6.6.1"

  name        = "terraform-state-access"
  path        = "/"
  description = "S3 list/get/put/delete on the Terraform state bucket. Nothing else."
  policy      = data.aws_iam_policy_document.terraform_state_access.json

  tags = {
    Terraform   = "true"
    Environment = "dev"
  }
}

data "aws_iam_policy_document" "terraform_state_access" {
  statement {
    sid       = "TerraformStateBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketVersioning", "s3:GetBucketLocation"]
    resources = [module.tfstate_bucket.s3_bucket_arn]
  }
  statement {
    sid       = "TerraformStateObjects"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${module.tfstate_bucket.s3_bucket_arn}/*"]
  }
}

# Role GitHub Actions assumes via OIDC. Trust is scoped to this repo only
# (repo:<org>/<repo>:* — the module prefixes "repo:" itself).
#
# use_name_prefix = false keeps the role name EXACTLY "terraform-state-access"
# (no random suffix) so its ARN is stable and a workflow can name it in
# configure-aws-credentials.
module "terraform_state_access_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role"
  version = "6.6.1"

  name               = "terraform-state-access"
  use_name_prefix    = false
  description        = "Assumed by GitHub Actions (${var.github_org}/${var.github_repo}) via OIDC: Terraform state bucket R/W only."
  enable_github_oidc = true

  oidc_wildcard_subjects = ["${var.github_org}/${var.github_repo}:*"]

  policies = {
    state-access = module.terraform_state_access_policy.arn
  }

  tags = {
    Terraform   = "true"
    Environment = "dev"
  }

  # The trust policy references the OIDC provider by ARN; it must exist first.
  depends_on = [module.iam_oidc_provider]
}
