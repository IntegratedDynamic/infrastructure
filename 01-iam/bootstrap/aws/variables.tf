variable "region" {
  description = "AWS region the provider operates in."
  type        = string
  default     = "eu-west-3"
}

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

# ── 00-foundation/aws remote state (cross-root read) ─────────────────────────
# 00-foundation/aws never migrates off AWS — see main.tf's data source
# comment — so these values are expected to stay constant. Parametrized
# anyway for consistency with every other cross-root state reference in the
# repo, and so the target is visible as config here, not hardcoded in main.tf.

variable "remote_state_aws_bucket" {
  description = "S3 bucket holding 00-foundation/aws's own remote state."
  type        = string
  default     = "id-terraform-state20260612164136440800000001"
}

variable "remote_state_aws_region" {
  description = "AWS region of remote_state_aws_bucket."
  type        = string
  default     = "eu-west-3"
}

variable "remote_state_aws_key" {
  description = "Object key for 00-foundation/aws's state within remote_state_aws_bucket."
  type        = string
  default     = "00-foundation/aws/00-foundation-aws-dev/terraform.tfstate"
}
