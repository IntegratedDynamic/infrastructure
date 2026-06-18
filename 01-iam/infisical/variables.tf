variable "org_id" {
  description = "Infisical organization ID the GitHub Actions identity is created in."
  type        = string
  default     = "73133541-f1c4-40d5-93f5-a5e073ab0264"
}

variable "project_id" {
  description = "Infisical project (workspace) ID the identity is granted access to. Defaults to the Platform project."
  type        = string
  default     = "7ecb6ed4-058a-46cd-ac9f-7e792469cf0f"
}

variable "project_role_slug" {
  description = "Project role granted to the GitHub Actions identity. 'viewer' = read-only secret access."
  type        = string
  default     = "viewer"
}

# Trust is scoped to exactly one repo: repo:<org>/<repo>:* . Only workflows in
# this repo can present an OIDC token Infisical will accept.
variable "github_org" {
  description = "GitHub organization that owns the repo allowed to authenticate."
  type        = string
  default     = "IntegratedDynamic"
}

variable "github_repo" {
  description = "GitHub repository whose workflows may authenticate (sub claim is scoped to it)."
  type        = string
  default     = "infrastructure"
}

variable "github_oidc_audience" {
  description = "Expected `aud` claim on the GitHub OIDC token. Defaults to GitHub's repository-owner default audience."
  type        = string
  default     = "https://github.com/IntegratedDynamic"
}

variable "access_token_ttl" {
  description = "Lifetime (seconds) of the Infisical access token CI receives after OIDC login."
  type        = number
  default     = 600
}
