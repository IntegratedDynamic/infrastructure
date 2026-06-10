variable "bucket_name" {
  description = "Globally-unique name of the Object Storage bucket holding the org's Terraform remote state. Bucket names are unique across all of Scaleway, so override this if it collides."
  type        = string
  default     = "id-terraform-state"
}

variable "region" {
  description = "Scaleway region the state bucket lives in. Drives the S3-compatible endpoint (https://s3.<region>.scw.cloud) other roots point their backend at."
  type        = string
  default     = "fr-par"
}

variable "noncurrent_version_expiration_days" {
  description = "Number of days after which NONCURRENT (superseded) state versions are expired. The current version is never expired — this only trims the history so it doesn't grow unbounded."
  type        = number
  default     = 10
}
