# AWS region the role/provider operate in. IAM is global, but the provider still
# wants a region; keep it aligned with the state bucket's region (eu-west-3).
variable "region" {
  description = "AWS region the provider operates in. Matches the state bucket region."
  type        = string
  default     = "eu-west-3"
}

# The trust policy is scoped to exactly one repo: repo:<org>/<repo>:* . Only
# workflows in this repo can assume the role, regardless of branch/PR/tag.
variable "github_org" {
  description = "GitHub organization that owns the repo allowed to assume the role."
  type        = string
  default     = "IntegratedDynamic"
}

variable "github_repo" {
  description = "GitHub repository whose workflows may assume the role (sub claim is scoped to it)."
  type        = string
  default     = "infrastructure"
}

# The shared org Terraform state bucket (same one every root's backend points at).
# Used to scope the role's S3 policy to exactly that bucket.
variable "state_bucket_name" {
  description = "Name of the shared S3 bucket holding the org's Terraform remote state."
  type        = string
  default     = "id-terraform-state20260612164136440800000001"
}

variable "state_bucket_arn" {
  description = "ARN of the state bucket — arn:aws:s3:::<state_bucket_name>."
  type        = string
  default     = "arn:aws:s3:::id-terraform-state20260612164136440800000001"
}

# Name of the permissions-boundary managed policy. Kept as a stable, fixed name
# (not a generated one) so its ARN can be constructed deterministically — the
# boundary references its own ARN in a Deny, and the CI grant references it in
# every guardrail condition. See iam-ci.tf.
variable "boundary_name" {
  description = "Name of the permissions-boundary policy capping all CI-created roles."
  type        = string
  default     = "tf-managed-boundary"
}
