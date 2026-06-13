# The role ARN is what workflows pass to aws-actions/configure-aws-credentials as
# `role-to-assume`. It's known only after apply, so it's wired into CI via the
# repo variable vars.AWS_GITHUB_ACTIONS_ROLE_ARN (set by hand post-apply — see
# README). Not a secret: an ARN is a public identifier.
output "role_arn" {
  description = "ARN of the IAM role GitHub Actions assumes via OIDC (set as vars.AWS_GITHUB_ACTIONS_ROLE_ARN)."
  value       = aws_iam_role.github_actions.arn
}
