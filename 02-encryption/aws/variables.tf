variable "aws_region" {
  description = "AWS region for the OpenBao auto-unseal KMS key. Defaults to the state bucket region to keep all AWS resources colocated."
  type        = string
  default     = "eu-west-3"
}
