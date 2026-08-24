# =============================================================================
# OpenBao auto-unseal — native AWS KMS.
#
# OpenBao runs on Scaleway Kapsule, which is NOT AWS: there is no instance
# profile / IRSA to lean on, so the `seal "awskms"` stanza must authenticate
# with a STATIC AWS access key. This root therefore provisions:
#
#   1. A symmetric KMS key (the unseal key — encrypts OpenBao's root key).
#   2. A dedicated, single-purpose IAM user whose ONLY capability is to
#      Encrypt/Decrypt/DescribeKey against this one key (granted via the key
#      policy, not an IAM policy — the user holds no IAM permissions at all).
#   3. A static access key for that user, surfaced as outputs.
#
# The access key id + secret feed OpenBao's pod env (AWS_ACCESS_KEY_ID /
# AWS_SECRET_ACCESS_KEY) alongside the KMS key id, e.g.:
#
#   seal "awskms" {
#     region     = "<aws_region>"
#     kms_key_id = "<kms_key_id output>"
#   }
#
# APPLY PATH — local or CI, via the openbao-unseal-ci role (see version.tf).
# =============================================================================

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  # Hardcoded, NOT derived from terraform.workspace (2026-08-24
  # workspace-naming refacto): this name feeds a real AWS IAM user + KMS
  # alias below, and aws_iam_access_key.user is ForceNew — if the IAM
  # user's name changed, the access key would be destroyed and recreated,
  # rotating OpenBao's unseal credential out from under it until the new
  # key is repropagated via gitops. Kept frozen at the value it had before
  # this root's workspace was renamed (was 03-backup-dev-bucket, matching
  # this root's old home inside 03-storage/scaleway before extraction) so
  # the workspace can be renamed to match this root's own path without
  # touching any live AWS resource.
  unseal_name = "openbao-unseal-03-backup-dev-bucket"
}

# -----------------------------------------------------------------------------
# The IAM user OpenBao authenticates as. It carries NO IAM policy — its only
# capability comes from the KMS key policy below (least privilege: it cannot
# touch any other key or AWS resource even if the access key leaks).
# -----------------------------------------------------------------------------
resource "aws_iam_user" "openbao_unseal" {
  name = local.unseal_name
  path = "/openbao/"

  tags = {
    Terraform   = "true"
    Environment = "dev"
    Purpose     = "openbao-auto-unseal"
  }
}

# Scaleway-side keys carry an expiry (see modules/scaleway-machine-identity);
# AWS access keys do not expire on their own. Rotation is a manual operator
# action: taint this key, re-apply, then update the OpenBao Secret. Kept
# static because OpenBao must read it at every pod start (including
# unattended restarts), with no human in the loop.
resource "aws_iam_access_key" "openbao_unseal" {
  user = aws_iam_user.openbao_unseal.name
}

# -----------------------------------------------------------------------------
# The unseal key. Symmetric, auto-rotated (transparent — the key id is stable,
# so OpenBao keeps unsealing across rotations). prevent_destroy because losing
# this key permanently bricks OpenBao: it must outlive ephemeral cluster resets.
# -----------------------------------------------------------------------------
resource "aws_kms_key" "openbao_unseal" {
  description             = "OpenBao auto-unseal key (${terraform.workspace}). Wraps OpenBao's root key; destroying it permanently bricks the OpenBao store."
  deletion_window_in_days = 30
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.openbao_unseal_key.json

  tags = {
    Terraform   = "true"
    Environment = "dev"
    Purpose     = "openbao-auto-unseal"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "openbao_unseal" {
  name          = "alias/${local.unseal_name}"
  target_key_id = aws_kms_key.openbao_unseal.key_id
}

# Key policy = the single source of access for this key:
#   - account root keeps full administrative control (so the key is never
#     orphaned and can always be managed via IAM / the console).
#   - the OpenBao user gets exactly the three crypto actions auto-unseal needs.
data "aws_iam_policy_document" "openbao_unseal_key" {
  statement {
    sid    = "EnableRootAccountAdmin"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
    actions   = ["kms:*"]
    resources = ["*"]
  }

  statement {
    sid    = "AllowOpenBaoAutoUnseal"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = [aws_iam_user.openbao_unseal.arn]
    }
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:DescribeKey",
    ]
    resources = ["*"]
  }
}
