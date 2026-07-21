variable "project_id" {
  description = "Scaleway project ID for IAM resource scoping. Must be the project scalepack.fr's DNS zone lives in."
  type        = string
}

variable "api_key_rotation_days" {
  description = "Rotation window (days) for the external-dns API key expiry."
  type        = number
  default     = 365
}
