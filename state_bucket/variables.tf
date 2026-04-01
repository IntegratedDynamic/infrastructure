variable "aws_region" {
  type    = string
  default = "eu-west-3"
}

variable "bucket_name_prefix" {
  type        = string
  description = "Name of the S3 bucket used for Terraform state"
  default = "terraform-states"
}

variable "aws_profile" {
  type = string
  default = "Sandbox"
}
