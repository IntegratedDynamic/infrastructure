variable "infisical_client_id" {
  type = string
}

variable "infisical_client_secret" {
  type = string
}

variable "gitops_revision" {
  type    = string
  default = "main"
}

variable "argocd_admin_password_hash" {
  description = "Pre-computed bcrypt hash of the ArgoCD admin password. When set, Infisical is not consulted."
  type        = string
  # default     = ""
}

variable "scaleway_s3_secret_key" {
  description = "Scaleway S3 secret key for OpenBao backup bucket"
  type        = string
  sensitive   = true
  # default     = ""
}

variable "openbao_unseal_aws_access_key_id" {
  description = "AWS access key id OpenBao uses for KMS auto-unseal. From 03-backup/scaleway output `openbao_unseal_access_key_id`."
  type        = string
  sensitive   = true
  # default     = ""
}

variable "openbao_unseal_aws_secret_access_key" {
  description = "AWS secret access key OpenBao uses for KMS auto-unseal. From 03-backup/scaleway output `openbao_unseal_secret_access_key`."
  type        = string
  sensitive   = true
  # default     = ""
}
