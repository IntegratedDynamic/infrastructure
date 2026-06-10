# Holds the Terraform remote state for the whole org (see README.md).
resource "scaleway_object_bucket" "tfstate" {
  name   = var.bucket_name
  region = var.region

  # Recover a corrupt/truncated state push by rolling back to a prior version.
  versioning {
    enabled = true
  }

  lifecycle_rule {
    id      = "expire-noncurrent-state-versions"
    enabled = true

    # Only noncurrent versions expire; the current state is always kept.
    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_expiration_days
    }
  }

  # Deleting this would orphan every root's state.
  lifecycle {
    prevent_destroy = true
  }

  tags = {
    purpose   = "terraform-remote-state"
    terraform = "true"
  }
}

# Separate resource (inline `acl` is deprecated). `private` keeps the bucket and
# its objects unreadable anonymously — state can hold sensitive values.
resource "scaleway_object_bucket_acl" "tfstate" {
  bucket = scaleway_object_bucket.tfstate.id
  acl    = "private"
  region = var.region
}
