# Research: Backup S3 Foundation

**Phase 0 output for `/speckit-plan`** — all NEEDS CLARIFICATION items resolved.

## 1. Scaleway Object Storage — Terraform Resources

**Decision**: Use `scaleway_object_bucket` (inline lifecycle_rule / versioning blocks) + separate `scaleway_object_bucket_server_side_encryption_configuration` + `scaleway_object_bucket_policy` for explicit deny.

**Rationale**: The Scaleway provider supports two styles for lifecycle configuration: inline blocks on `scaleway_object_bucket` and the standalone `scaleway_object_bucket_lifecycle_configuration` resource. The inline blocks are the current recommended pattern and cover all required attributes (expiration, transition, noncurrent_version_expiration, noncurrent_version_transition). Versioning is also inline (`versioning { enabled = true }`). SSE requires a separate resource (`scaleway_object_bucket_server_side_encryption_configuration`) to make encryption explicit in state.

**Alternatives considered**: `scaleway_object_bucket_lifecycle_configuration` standalone resource — rejected because inline blocks require fewer resources and avoid dependency ordering issues.

**Key resource attributes:**

```hcl
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

  lifecycle {
    prevent_destroy = true
    precondition {
      condition     = !var.cold_storage_enabled || var.cold_storage_transition_days < var.retention_days
      error_message = "cold_storage_transition_days must be strictly less than retention_days."
    }
  }
}
```

---

## 2. Scaleway IAM Permission Sets for Object Storage

**Decision**: Use layered defense for FR-014 (CI SHALL NOT have bucket deletion rights):
1. Scaleway IAM policy for CI identity: `ObjectStorageBucketsRead` + `ObjectStorageBucketsWrite` + `ObjectStorageObjectsRead` + `ObjectStorageObjectsWrite` (needed to create/manage bucket and its configuration)
2. `scaleway_object_bucket_policy` with explicit `Deny` on `s3:DeleteBucket` scoped to the CI application principal — overrides IAM allows
3. `lifecycle { prevent_destroy = true }` on the bucket Terraform resource — blocks destroy via Terraform
4. No scheduled destroy in the backup CI workflow (FR-013)

**Rationale**: Scaleway does not expose a "bucket create but not delete" IAM permission set. The only path to enforce the spec's FR-014 requirement is through an S3 bucket policy DENY statement, which takes precedence over IAM policy ALLOWs per Scaleway's IAM evaluation logic (same as AWS: explicit deny overrides allow). The `prevent_destroy` lifecycle provides Terraform-level defense in depth.

**Scoped backup workload identity permissions**: `ObjectStorageObjectsRead` + `ObjectStorageObjectsWrite`. These exclude all bucket-level administrative actions. Verification test: attempt `s3:DeleteBucket` with scoped credentials → denied by IAM (no bucket permission) + by bucket policy.

**Scaleway IAM permission sets confirmed available:**
- `ObjectStorageBucketsRead` — list/stat buckets
- `ObjectStorageBucketsWrite` — full bucket CRUD (create, update, delete)
- `ObjectStorageObjectsRead` — read/list objects
- `ObjectStorageObjectsWrite` — write/update/delete objects
- `ObjectStorageFullAccess` — all of the above

---

## 3. Encryption

**Decision**: `scaleway_object_bucket_server_side_encryption_configuration` with `sse_algorithm = "AES256"`.

**Rationale**: AES-256 SSE is the cost-free default for Scaleway Object Storage. Scaleway also offers KMS-based SSE (`aws:kms`) but it requires provisioning a KMS key, which introduces cost and operational overhead. The spec only requires encryption enabled (FR-001) with no KMS mandate.

```hcl
resource "scaleway_object_bucket_server_side_encryption_configuration" "backup" {
  bucket = scaleway_object_bucket.backup.name
  region = var.region

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
```

---

## 4. FR-016 Validation Strategy

**Decision**: Terraform `lifecycle { precondition {...} }` block on `scaleway_object_bucket`.

**Rationale**: Preconditions on resources evaluate at plan time, before any apply, and produce a clear error message. This is the canonical Terraform pattern for validating cross-variable constraints. A `variable { validation {...} }` block on individual variables cannot cross-reference other variables, so a resource-level precondition is the only viable approach for the "transition_days < retention_days" constraint.

**Condition**: `!var.cold_storage_enabled || var.cold_storage_transition_days < var.retention_days`
- When cold storage is disabled: constraint is bypassed (vacuously true)
- When cold storage is enabled: transition delay must be strictly less than retention period

---

## 5. Workload Identity Strategy — Static Credentials via Infisical

**Decision**: Credentials statiques (API key Scaleway) générées par Terraform, stockées dans Infisical, injectées comme variables d'environnement dans le pod via ESO (External Secrets Operator). Pas de pod workload identity.

**Rationale**: Scaleway Kapsule ne supporte pas le mapping IAM → Kubernetes ServiceAccount (IRSA-equivalent). C'est une [feature request ouverte](https://feature-request.scaleway.com/posts/677/map-iam-to-kubernetes-kapsule-service-account) sans date d'implémentation connue. La seule option disponible est donc une API key statique distribuée via Infisical.

**Chemin complet** : `03-backup/scaleway apply` → `scaleway_iam_api_key` → `infisical_secret` → ESO lit depuis Infisical → `kind: Secret` Kubernetes → pod monte `SCW_ACCESS_KEY` + `SCW_SECRET_KEY` comme env vars.

## 5b. CI Credentials Strategy

**Decision**: Add a new IAM policy to the existing `github-ci` Scaleway application (in `01-iam/bootstrap/scaleway/main.tf`) covering Object Storage management + IAM application/policy/API key management. The backup CI workflow reuses the existing `scaleway` GitHub environment.

**Rationale**: Creating a second Scaleway IAM application and a second set of API key secrets in GitHub would require a new GitHub environment or secret naming convention, adding operational overhead. Extending the existing `github-ci` application is consistent with how the cluster CI credentials work (one application, one API key, all CI use cases). The expanded permissions are scoped to the project and remain within the principle of least-privilege for what the backup root needs.

**Permissions to add to `github-ci`**:
- `ObjectStorageBucketsRead` + `ObjectStorageBucketsWrite` — create/manage bucket (deletion enforced-denied by bucket policy)
- `ObjectStorageObjectsRead` + `ObjectStorageObjectsWrite` — manage bucket content (needed for Terraform refresh on object resources)
- IAM application/policy/API key management — provision the scoped backup workload identity

**Alternatives considered**: New dedicated IAM application for backup CI — rejected for initial delivery. Can be revisited when a second environment (`prod`) is added and credential isolation becomes a priority.

---

## 6. State Isolation

**Decision**: New remote S3 backend root with `workspace_key_prefix = "backup/scaleway"`, workspace name `dev` (from `env/dev.tfvars`).

**Rationale**: This root has no Terraform dependency on the cluster roots and must survive cluster destroy/apply cycles. A completely separate state key guarantees isolation. The naming follows the pattern of `cluster/scaleway` already in use.

---

## 7. CI Verification Approach

**Decision**: Add a `verify` job to the backup CI workflow using the AWS CLI with the Scaleway S3-compatible endpoint (`https://s3.{region}.scw.cloud`). The verification job runs after `terraform apply` only on push to main.

**Rationale**: The AWS CLI is already present in GitHub Actions ubuntu-latest runners. Using it against Scaleway's S3-compatible API requires no new tooling. The `scw` CLI is an alternative but is not guaranteed to be present in runners without setup.

**Verification commands** (using AWS CLI with Scaleway endpoint):
```bash
# Bucket encryption (FR-009)
aws --endpoint-url "https://s3.${REGION}.scw.cloud" s3api get-bucket-encryption --bucket "$BUCKET_NAME"

# Versioning (FR-009)
aws --endpoint-url "https://s3.${REGION}.scw.cloud" s3api get-bucket-versioning --bucket "$BUCKET_NAME"

# Lifecycle rules (FR-010)
aws --endpoint-url "https://s3.${REGION}.scw.cloud" s3api get-bucket-lifecycle-configuration --bucket "$BUCKET_NAME"

# Scoped credential scope test (FR-011)
AWS_ACCESS_KEY_ID="$WORKLOAD_ACCESS_KEY" AWS_SECRET_ACCESS_KEY="$WORKLOAD_SECRET_KEY" \
  aws --endpoint-url "https://s3.${REGION}.scw.cloud" s3api put-object --bucket "$BUCKET_NAME" --key "ci-verify/probe.txt" --body /dev/null
AWS_ACCESS_KEY_ID="$WORKLOAD_ACCESS_KEY" AWS_SECRET_ACCESS_KEY="$WORKLOAD_SECRET_KEY" \
  aws --endpoint-url "https://s3.${REGION}.scw.cloud" s3api get-object --bucket "$BUCKET_NAME" --key "ci-verify/probe.txt" /dev/null
# Expect non-zero exit:
AWS_ACCESS_KEY_ID="$WORKLOAD_ACCESS_KEY" AWS_SECRET_ACCESS_KEY="$WORKLOAD_SECRET_KEY" \
  aws --endpoint-url "https://s3.${REGION}.scw.cloud" s3api delete-bucket --bucket "$BUCKET_NAME" \
  && echo "::error::Scoped credentials should NOT be able to delete the bucket" && exit 1 \
  || echo "Bucket deletion correctly denied"
```

Scoped credentials are read from Infisical at verify time or surfaced via Terraform outputs (sensitive).

---

## 8. Bucket Policy for CI Deletion Deny

**Decision**: `scaleway_object_bucket_policy` with explicit Deny on `s3:DeleteBucket` for the CI IAM application principal.

```hcl
resource "scaleway_object_bucket_policy" "backup" {
  bucket = scaleway_object_bucket.backup.name
  region = var.region

  policy = jsonencode({
    Version = "2023-04-17"
    Statement = [
      {
        Sid       = "DenyBucketDeletionForCI"
        Effect    = "Deny"
        Principal = { SCW = "application_id:${var.ci_application_id}" }
        Action    = ["s3:DeleteBucket"]
        Resource  = [scaleway_object_bucket.backup.name]
      }
    ]
  })
}
```

The CI application ID is passed via `var.ci_application_id` in `env/dev.tfvars`. It is stable (never changes after `01-iam/bootstrap/scaleway` is applied) and safe to hardcode in tfvars.
