resource "scaleway_object_bucket" "backup" {
  name   = var.bucket_name
  region = var.region

  versioning {
    enabled = var.versioning_enabled
  }

  lifecycle_rule {
    id      = "backup-retention"
    enabled = true

    expiration {
      days = var.retention_days
    }

    # FinOps safeguard: avoids paying for stale superseded versions.
    # The true backup retention policy (frequency, tiers, RTO/RPO) will be
    # defined at the backup-solution layer (e.g. Velero schedule), not here.
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

  # Deletion intentionally NOT protected at the provider level — see spec FR-014.
  # Bucket deletion is a manual-only, human-operator action with admin credentials.
  # Scaleway bucket policies do not support s3:DeleteBucket as an action, so the
  # protection relies on two layers: (1) prevent_destroy below blocks terraform destroy,
  # (2) no destroy trigger in the backup CI workflow blocks automated deletion.

  lifecycle {
    prevent_destroy = true

    precondition {
      condition     = !var.cold_storage_enabled || var.cold_storage_transition_days < var.retention_days
      error_message = "cold_storage_transition_days (${var.cold_storage_transition_days}) must be strictly less than retention_days (${var.retention_days}) when cold_storage_enabled is true. See spec FR-016."
    }
  }
}

resource "scaleway_object_bucket_server_side_encryption_configuration" "backup" {
  bucket = scaleway_object_bucket.backup.name
  region = var.region

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
