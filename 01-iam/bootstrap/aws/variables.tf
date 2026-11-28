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

variable "state_access_policy_arn" {
  description = "00-foundation/aws's state-bucket policy, attached to this role too rather than duplicating it. Passed by this root's Terragrunt unit from that root's output."
  type        = string
}

variable "aws_profile" {
  description = "AWS CLI profile the AWS provider authenticates with. An explicit profile wins over AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY, which hold the Scaleway state key. null: the SDK's default chain (CI with an assumed role)."
  type        = string
  default     = null
}
