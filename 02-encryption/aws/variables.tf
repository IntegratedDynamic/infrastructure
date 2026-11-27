variable "aws_region" {
  description = "AWS region for the OpenBao auto-unseal KMS key. Defaults to the state bucket region to keep all AWS resources colocated."
  type        = string
  default     = "eu-west-3"
}

variable "workspace_name" {
  description = <<-EOT
    Only used in the KMS key's description, e.g. "02-encryption-aws-main". live/root.hcl passes
    it: "<root path flattened>-<instance>". The IAM user / KMS alias names
    do NOT come from it (local.unseal_name is frozen, see main.tf).
  EOT
  type        = string
}

variable "aws_profile" {
  description = "AWS CLI profile the AWS provider authenticates with. An explicit profile wins over AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY, which hold the Scaleway state key. null: the SDK's default chain (CI with an assumed role)."
  type        = string
  default     = null
}
