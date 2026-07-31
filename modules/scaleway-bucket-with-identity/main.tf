resource "scaleway_object_bucket" "this" {
  name   = var.bucket_name
  region = var.region

  versioning {
    enabled = var.versioning_enabled
  }

  lifecycle_rule {
    id      = var.lifecycle_rule_id
    enabled = true

    expiration {
      days = var.retention_days
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

module "identity" {
  source = "../scaleway-machine-identity"

  application_name        = var.identity_application_name
  application_description = var.identity_application_description

  policies = {
    default = {
      name        = var.identity_policy_name
      description = var.identity_policy_description
      rules = [
        {
          project_ids          = [var.project_id]
          permission_set_names = var.identity_permission_set_names
        }
      ]
    }
  }

  project_id           = var.project_id
  api_key_description  = var.api_key_description
}
