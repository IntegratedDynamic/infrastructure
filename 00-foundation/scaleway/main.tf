# One dedicated Object Storage bucket per consuming root module — see
# README.md ("Why per-root buckets, not one shared bucket") for why this
# isn't a single shared bucket the way 00-foundation/aws is. By default, each
# bucket also gets its OWN least-privilege identity (create_identity = true,
# the module's default) — a basic CRUD-on-this-bucket-only role is exactly
# what every root's own backend needs, at minimum. A root that needs broader
# Scaleway rights than that gets its own identity in 01-iam/ instead
# (create_identity = false here, so this module doesn't create a redundant
# one) — see var.state_buckets.
#
# expiration_enabled = false: unlike the module's usual tool-bucket use case
# (03-storage/scaleway), a state bucket's current-version object must NEVER
# expire regardless of age — only noncurrent_version_expiry_days applies.
# Mirrors 00-foundation/aws's own bucket for the same reason.
module "state_buckets" {
  source   = "../../modules/scaleway-bucket-with-identity"
  for_each = var.state_buckets

  bucket_name       = each.value.bucket_name
  region            = coalesce(each.value.region, var.region)
  lifecycle_rule_id = "expire-noncurrent-state-versions"

  versioning_enabled             = true
  expiration_enabled             = false
  noncurrent_version_expiry_days = coalesce(each.value.noncurrent_version_expiration_days, var.noncurrent_version_expiration_days)
  cold_storage_enabled           = false

  project_id      = var.project_id
  create_identity = coalesce(each.value.create_identity, true)

  # identity_application_name / identity_policy_name / descriptions /
  # api_key_description left unset on purpose — the module generates clean,
  # unique-by-construction names from bucket_name (itself already globally
  # unique). identity_permission_set_names left at the module default too
  # (object R/W/delete + bucket read — exactly what a backend needs).
}
