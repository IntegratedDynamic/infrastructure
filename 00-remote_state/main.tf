# Holds the Terraform remote state for the whole org (see README.md).
# Uses the community terraform-aws-modules/s3-bucket module.
module "tfstate_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 5.0"

  bucket_prefix = var.bucket_prefix

  # Recover a corrupt/truncated state push by rolling back to a prior version.
  versioning = {
    enabled = true
  }

  # Encrypt every object at rest (SSE-S3, AES256 — no KMS key to manage).
  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm = "AES256"
      }
    }
  }

  # ACLs disabled, bucket owner owns everything — the modern replacement for a
  # `private` ACL. Combined with the public-access block below, the bucket and
  # its objects are unreachable anonymously (state can hold sensitive values).
  control_object_ownership = true
  object_ownership         = "BucketOwnerEnforced"

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  # Reject any non-TLS request to the state — defence in depth for secrets.
  attach_deny_insecure_transport_policy = true

  # Guard against accidentally deleting everyone's state: force_destroy stays
  # off, so `terraform destroy` fails while objects remain.
  force_destroy = false

  lifecycle_rule = [
    {
      id     = "expire-noncurrent-state-versions"
      status = "Enabled"

      # Empty filter == applies to the whole bucket.
      filter = {}

      # Only noncurrent (superseded) versions expire; the current state is kept.
      noncurrent_version_expiration = {
        days = var.noncurrent_version_expiration_days
      }
    }
  ]

  tags = {
    purpose   = "terraform-remote-state"
    terraform = "true"
  }
}
