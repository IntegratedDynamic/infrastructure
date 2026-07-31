# One bucket + one scoped workload identity per entry, via
# modules/scaleway-bucket-with-identity. Add a new tool bucket by adding a new
# map entry here — no new .tf resources needed.
variable "buckets" {
  description = "Map of bucket key => config."
  type = map(object({
    bucket_name            = string
    identity_app_prefix    = string
    identity_policy_prefix = string
    identity_purpose       = string
    api_key_purpose        = string
    api_key_consumer       = string
  }))
}

variable "region" {
  description = "Scaleway region for the buckets."
  type        = string
  default     = "fr-par"
}

# ── Lifecycle (shared across every bucket in var.buckets) ───────────────────

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
  description = "Days before objects are transitioned to GLACIER. Only evaluated when cold_storage_enabled = true. Must be less than retention_days."
  type        = number
  default     = 90
}

# ── Identity ─────────────────────────────────────────────────────────────────

variable "project_id" {
  description = "Scaleway project ID for bucket and IAM resource scoping."
  type        = string
}
