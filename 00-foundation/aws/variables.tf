variable "bucket_prefix" {
  description = "prefix of the S3 bucket holding the org's Terraform remote state."
  type        = string
  default     = "id-terraform-state"
}

variable "region" {
  description = "AWS region the state bucket lives in. Must match the `region` hardcoded in every consuming root's backend \"s3\" block."
  type        = string
  default     = "eu-west-3"
}

variable "noncurrent_version_expiration_days" {
  description = "Number of days after which NONCURRENT (superseded) state versions are expired. The current version is never expired — this only trims the history so it doesn't grow unbounded."
  type        = number
  default     = 10
}

# The trust policy is scoped to exactly one repo: repo:<org>/<repo>:* . Only
# workflows in this repo can assume the role, regardless of branch/PR/tag.
variable "github_org" {
  description = "GitHub organization that owns the repo allowed to assume the Terraform state access role."
  type        = string
  default     = "IntegratedDynamic"
}

variable "github_repo" {
  description = "GitHub repository whose workflows may assume the Terraform state access role (sub claim is scoped to it)."
  type        = string
  default     = "infrastructure"
}
