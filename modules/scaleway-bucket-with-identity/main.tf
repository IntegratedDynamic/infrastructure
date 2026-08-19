locals {
  # Auto-generated, unless the caller supplies its own — derived from
  # bucket_name, which Scaleway already guarantees is globally unique, so
  # these are unique-by-construction with zero extra machinery (no random
  # suffix needed) and traceable back to their bucket at a glance. Suffixes
  # kept short (Scaleway IAM application/policy names cap at 64 runes) and
  # truncated defensively with substr() so a future long bucket_name can't
  # blow the limit and hard-fail the apply.
  identity_application_name        = coalesce(var.identity_application_name, substr("${var.bucket_name}-access", 0, 64))
  identity_application_description = coalesce(var.identity_application_description, "Machine identity scoped to the ${var.bucket_name} bucket.")
  identity_policy_name             = coalesce(var.identity_policy_name, substr("${var.bucket_name}-objects", 0, 64))
  identity_policy_description      = coalesce(var.identity_policy_description, "Object-level read/write on the ${var.bucket_name} bucket. Project-scoped: Scaleway IAM can't scope below project level.")
  api_key_description              = coalesce(var.api_key_description, "Terraform-managed credentials for ${var.bucket_name}.")
}

resource "scaleway_object_bucket" "this" {
  name   = var.bucket_name
  region = var.region

  versioning {
    enabled = var.versioning_enabled
  }

  lifecycle_rule {
    id      = var.lifecycle_rule_id
    enabled = true

    # Disabled (expiration_enabled = false) for callers whose current-version
    # object must never expire regardless of age — e.g. Terraform state
    # buckets, where only noncurrent_version_expiration below applies.
    dynamic "expiration" {
      for_each = var.expiration_enabled ? [var.retention_days] : []
      content {
        days = expiration.value
      }
    }

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_expiry_days
    }

    dynamic "transition" {
      for_each = var.cold_storage_enabled ? [var.cold_storage_transition_days] : []
      content {
        days          = transition.value
        storage_class = "GLACIER"
      }
    }
  }

  # Deletion intentionally NOT protected at the provider level. Bucket
  # deletion is a manual-only, human-operator action with admin credentials.
  # Scaleway bucket policies do not support s3:DeleteBucket as an action, so
  # the protection relies on two layers: (1) prevent_destroy below blocks
  # terraform destroy, (2) no destroy trigger in any CI workflow that applies
  # this root.
  lifecycle {
    prevent_destroy = true

    precondition {
      condition     = !var.cold_storage_enabled || var.cold_storage_transition_days < var.retention_days
      error_message = "cold_storage_transition_days (${var.cold_storage_transition_days}) must be strictly less than retention_days (${var.retention_days}) when cold_storage_enabled is true."
    }
  }
}

resource "scaleway_object_bucket_server_side_encryption_configuration" "this" {
  bucket = scaleway_object_bucket.this.name
  region = var.region

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# create_identity defaults to true: most buckets want their own scoped
# identity. A caller that already has (or will create, e.g. in 01-iam/) a
# broader identity of its own sets this false instead.
module "identity" {
  source = "../scaleway-machine-identity"
  count  = var.create_identity ? 1 : 0

  application_name        = local.identity_application_name
  application_description = local.identity_application_description

  policies = {
    default = {
      name        = local.identity_policy_name
      description = local.identity_policy_description
      rules = [
        {
          project_ids          = [var.project_id]
          permission_set_names = var.identity_permission_set_names
        }
      ]
    }
  }

  project_id          = var.project_id
  api_key_description = local.api_key_description
}
