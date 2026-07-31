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
