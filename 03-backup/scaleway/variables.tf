variable "bucket_name" {
  description = "Backup bucket name. Must include the environment name (e.g. backup-dev-id). See spec FR-015."
  type        = string
}

variable "region" {
  description = "Scaleway region for the bucket."
  type        = string
  default     = "fr-par"
}

variable "aws_region" {
  description = "AWS region for the OpenBao auto-unseal KMS key (kms.tf). Defaults to the state bucket region to keep all AWS resources colocated."
  type        = string
  default     = "eu-west-3"
}

# ── Lifecycle ────────────────────────────────────────────────────────────────

variable "versioning_enabled" {
  description = "Enable bucket versioning. Once enabled, can only be suspended, never disabled."
  type        = bool
  default     = true
}

variable "retention_days" {
  description = "Days before current-version objects expire."
  type        = number
  default     = 365
}

variable "noncurrent_version_expiry_days" {
  description = "Days before non-current object versions are deleted."
  type        = number
  default     = 30
}

variable "cold_storage_enabled" {
  description = "Enable transition of objects to GLACIER storage class."
  type        = bool
  default     = true
}

variable "cold_storage_transition_days" {
  description = "Days before objects are transitioned to GLACIER. Only evaluated when cold_storage_enabled = true. Must be less than retention_days (FR-016)."
  type        = number
  default     = 90
}

# ── Identity ─────────────────────────────────────────────────────────────────

variable "project_id" {
  description = "Scaleway project ID for bucket and IAM resource scoping."
  type        = string
}

variable "ci_application_id" {
  description = "IAM application ID of the github-ci identity (from 01-iam/bootstrap/scaleway outputs). Reserved for a future bucket policy Deny statement if Scaleway adds s3:DeleteBucket support."
  type        = string
  default     = ""
}

# ── Infisical ────────────────────────────────────────────────────────────────

variable "infisical_workspace_id" {
  description = "Infisical project (workspace) ID."
  type        = string
  default     = "7ecb6ed4-058a-46cd-ac9f-7e792469cf0f"
}

variable "infisical_env_slug" {
  description = "Infisical environment slug."
  type        = string
  default     = "staging"
}

variable "infisical_folder_path" {
  description = "Infisical folder path where backup workload credentials are written."
  type        = string
  default     = "/backup"
}

variable "infisical_client_id" {
  description = "Infisical universal auth client ID. Set for local development; leave empty when using OIDC in CI."
  type        = string
  default     = ""
}

variable "infisical_client_secret" {
  description = "Infisical universal auth client secret. Set for local development; leave empty when using OIDC in CI."
  type        = string
  sensitive   = true
  default     = ""
}
