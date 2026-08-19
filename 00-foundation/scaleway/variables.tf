# One entry per consuming root module needing a Scaleway-hosted Terraform
# state bucket. Add a future root's bucket by adding a map entry — no new
# resources needed (see README.md for why one bucket per root, not shared).
variable "state_buckets" {
  description = "Map of root-module slug => its dedicated Terraform state bucket config."
  type = map(object({
    bucket_name                        = string
    region                             = optional(string)
    noncurrent_version_expiration_days = optional(number)
    # Whether this bucket gets its own dedicated identity (module default:
    # true — a basic CRUD-on-this-bucket-only role is what every root needs
    # at minimum). Set false for a root that already has, or will get, a
    # broader identity of its own in 01-iam/ instead.
    create_identity = optional(bool, true)
  }))
}

variable "region" {
  description = "Default Scaleway region for buckets that don't override it per entry."
  type        = string
  default     = "fr-par"
}

variable "noncurrent_version_expiration_days" {
  description = "Default days after which NONCURRENT (superseded) state versions expire, for buckets that don't override it per entry. The current version is never expired."
  type        = number
  default     = 10
}

variable "project_id" {
  description = "Scaleway project ID for bucket and IAM resource scoping."
  type        = string
}
