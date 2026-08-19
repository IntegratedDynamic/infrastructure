variable "bucket_name" {
  description = "Bucket name. Must include the environment name (e.g. backup-dev-id)."
  type        = string
}

variable "lifecycle_rule_id" {
  description = "ID of the bucket's lifecycle_rule block. Distinct per bucket only because Scaleway requires each bucket's rule to have an id."
  type        = string
  default     = "retention"
}

variable "region" {
  description = "Scaleway region for the bucket."
  type        = string
  default     = "fr-par"
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
  description = "Days before objects are transitioned to GLACIER. Only evaluated when cold_storage_enabled = true. Must be less than retention_days."
  type        = number
  default     = 90
}

variable "expiration_enabled" {
  description = "Whether current-version objects expire after retention_days. Default true (existing behavior). Set false for buckets whose current version must never expire regardless of age (e.g. Terraform state buckets) — noncurrent_version_expiry_days still applies either way."
  type        = bool
  default     = true
}

# ── Identity (modules/scaleway-machine-identity) ────────────────────────────

variable "project_id" {
  description = "Scaleway project ID for bucket and IAM resource scoping."
  type        = string
}

variable "create_identity" {
  description = "Whether to create a dedicated machine identity (IAM application + policy + API key) scoped to this bucket. Default true — most buckets want their own least-privilege identity; set false when a caller already has (or will create, e.g. in 01-iam/) its own broader identity instead."
  type        = bool
  default     = true
}

variable "identity_application_name" {
  description = "Name of the IAM application backing this bucket's workload identity. Left unset (null), auto-generated from bucket_name — which Scaleway already guarantees is globally unique — so it's unique-by-construction without extra machinery."
  type        = string
  default     = null
}

variable "identity_application_description" {
  description = "Description of the IAM application. Auto-generated from bucket_name when unset."
  type        = string
  default     = null
}

variable "identity_policy_name" {
  description = "Name of the IAM policy granting this identity access to the bucket. Auto-generated from bucket_name when unset — see identity_application_name."
  type        = string
  default     = null
}

variable "identity_policy_description" {
  description = "Description of the IAM policy. Auto-generated from bucket_name when unset."
  type        = string
  default     = null
}

variable "identity_permission_set_names" {
  description = "Scaleway permission sets granted to the identity, project-scoped (Scaleway IAM can't scope Object Storage permissions below project level, so this is the tightest available grant)."
  type        = list(string)
  default     = ["ObjectStorageObjectsRead", "ObjectStorageObjectsWrite", "ObjectStorageBucketsRead", "ObjectStorageObjectsDelete"]
}

variable "api_key_description" {
  description = "Description of the generated API key. Auto-generated from bucket_name when unset."
  type        = string
  default     = null
}
