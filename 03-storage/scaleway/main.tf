# Backup gets its own bucket + identity, separate from Velero's (gitops repo
# platform/scaleway/velero.yml) even though the permission set is identical:
# confirmed live (2026-07-28) that OpenBao's snapshot script does a flat
# `s3cmd ls` on the bucket root for its own retention cleanup and chokes on
# any object/prefix it doesn't own — Velero writing into a `velero/` prefix
# inside the backup bucket broke every subsequent OpenBao snapshot job.
# Scaleway's IAM can't scope Object Storage permissions below project level
# anyway, so a separate bucket — not a separate IAM policy — is what actually
# isolates the two. See variables.tf for the shape of var.buckets; add a new
# tool bucket by adding a new map entry, no new resources needed here.
module "buckets" {
  source   = "../../modules/scaleway-bucket-with-identity"
  for_each = var.buckets

  bucket_name       = each.value.bucket_name
  region            = var.region
  lifecycle_rule_id = "${each.key}-retention"

  versioning_enabled              = var.versioning_enabled
  retention_days                  = var.retention_days
  noncurrent_version_expiry_days  = var.noncurrent_version_expiry_days
  cold_storage_enabled            = var.cold_storage_enabled
  cold_storage_transition_days    = var.cold_storage_transition_days

  project_id                        = var.project_id
  identity_application_name         = "${each.value.identity_app_prefix}-${terraform.workspace}"
  identity_application_description  = "Kubernetes workload identity for ${terraform.workspace} — ${each.value.identity_purpose}."
  identity_policy_name              = "${each.value.identity_policy_prefix}-${terraform.workspace}"
  identity_policy_description       = "Object-level read/write on the ${each.key} project. No bucket-level permissions — cannot delete or reconfigure the bucket."
  api_key_description                = "${each.value.api_key_purpose} for ${terraform.workspace}. ${each.value.api_key_consumer}."
}
