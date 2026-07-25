variable "token_ttl_seconds" {
  description = "Default TTL of tokens minted from the terraform AppRole role."
  type        = number
  default     = 3600
}

variable "token_max_ttl_seconds" {
  description = "Max TTL a terraform AppRole token can be renewed to."
  type        = number
  default     = 14400
}

# OpenBao enforces no built-in expiry on secret_id like Scaleway does on API keys,
# so this is a repo convention, not a platform requirement — mirrors
# api_key_rotation_days in the other bootstrap roots.
variable "secret_id_ttl_days" {
  description = "Rotation window (days) for the AppRole secret_id before it stops being usable."
  type        = number
  default     = 90
}
