# The role ARN is what workflows pass to aws-actions/configure-aws-credentials as
# `role-to-assume`. It's known only after apply, so it's wired into CI via the
# repo variable vars.AWS_GITHUB_ACTIONS_ROLE_ARN (set by hand post-apply — see
# README). Not a secret: an ARN is a public identifier.
output "role_arn" {
  description = "ARN of the IAM role GitHub Actions assumes via OIDC (set as vars.AWS_GITHUB_ACTIONS_ROLE_ARN)."
  value       = module.iam_role_github_oidc.arn
}

# Every role the CI creates MUST carry this boundary, or the apply is rejected by
# the CI grant's conditions. Roots that create roles should attach it via the
# iam-role module's `permissions_boundary` input.
output "permissions_boundary_arn" {
  description = "ARN of the permissions boundary to attach to every CI-managed role."
  value       = local.boundary_arn
}

# The repo-scoped path every CI-managed role/policy must sit under. In CI, feed
# this to Terraform as TF_VAR_role_path=/tf-managed/${{ github.repository }}/ —
# it resolves to exactly this value. IAM paths are case-sensitive.
output "managed_path" {
  description = "IAM path prefix all CI-managed roles and policies must use."
  value       = local.managed_path
}
