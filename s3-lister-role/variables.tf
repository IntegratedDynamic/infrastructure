variable "region" {
  description = "AWS region the provider operates in. Matches the state bucket region."
  type        = string
  default     = "eu-west-3"
}

variable "role_name" {
  description = "Name of the org-wide S3-lister role."
  type        = string
  default     = "s3-lister"
}

# IAM path every CI-managed role must sit under. The CI grant (aws-github-oidc/)
# only allows role creation under this path WITH the boundary below — so both
# must be set or the apply is rejected. In CI this is fed automatically from the
# repo slug: TF_VAR_role_path=/tf-managed/${{ github.repository }}/ (see the
# workflow). The default lets `plan` work locally. IAM paths are case-sensitive.
variable "role_path" {
  description = "IAM path prefix for the role (must match the CI grant's managed path)."
  type        = string
  default     = "/tf-managed/IntegratedDynamic/infrastructure/"
}

# The permissions boundary that caps this role. Value is the
# `permissions_boundary_arn` output of the aws-github-oidc/ root. Required by the
# CI grant's conditions.
variable "permissions_boundary_arn" {
  description = "ARN of the permissions boundary to attach (aws-github-oidc output)."
  type        = string
  default     = "arn:aws:iam::503577850357:policy/tf-managed-boundary"
}

# AWS Organizations ID. Anyone whose credentials belong to this org may assume
# the role (aws:PrincipalOrgID trust condition). `aws organizations
# describe-organization --query Organization.Id`.
variable "org_id" {
  description = "AWS Organizations ID allowed to assume the role (aws:PrincipalOrgID)."
  type        = string
  default     = "o-f9lb1e5es9"
}

# GitHub OIDC subjects allowed to assume the role via web identity. Values are
# org/repo globs; the iam-role module prepends `repo:` and matches the token
# `sub` claim with StringLike. The org-wide default (`<org>/*`) lets ANY repo on
# ANY branch in the GitHub org assume the role keylessly — the GitHub-org
# analogue of the aws:PrincipalOrgID trust. Tighten to specific repos if needed.
variable "github_oidc_subjects" {
  description = "GitHub OIDC sub globs (org/repo, module prepends `repo:`) allowed to assume the role."
  type        = list(string)
  default     = ["IntegratedDynamic/*"]
}
