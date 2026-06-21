variable "infisical_workspace_id" {
  description = "Infisical project (workspace) ID the CI secrets are written to."
  type        = string
  default     = "7ecb6ed4-058a-46cd-ac9f-7e792469cf0f"
}

variable "infisical_env_slug" {
  description = "Infisical environment slug the CI secrets live in."
  type        = string
  default     = "staging"
}

variable "infisical_folder_path" {
  description = "Infisical folder the CI secrets are written to (kept separate from the cluster bootstrap secrets)."
  type        = string
  default     = "/ci"
}

# The default project shares the organization's UUID on Scaleway. The buckets the
# CI identity must list live here, so we scope the policy and the API key to it.
variable "project_id" {
  description = "Scaleway project the CI identity is scoped to (Object Storage buckets it may list)."
  type        = string
  default     = "6283c05b-a4c7-4f83-a75f-83adad236d54"
}

variable "organization_id" {
  description = "Scaleway organization ID. Used for org-scoped IAM permission sets (IAMApplicationManager, IAMPolicyManager)."
  type        = string
  default     = "6283c05b-a4c7-4f83-a75f-83adad236d54"
}

# Scaleway's org policy requires every API key to carry an expiry. This drives
# the key's expires_at; once the window elapses, the next apply rotates the key.
variable "api_key_rotation_days" {
  description = "Lifetime (days) of the CI API key before terraform rotates it on the next apply."
  type        = number
  default     = 365
}
