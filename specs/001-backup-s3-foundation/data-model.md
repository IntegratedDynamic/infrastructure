# Data Model: Backup S3 Foundation

## Entities

### BackupBucket

The Scaleway Object Storage bucket providing isolated, lifecycle-managed backup storage.

| Field | Type | Default | Constraint |
|-------|------|---------|------------|
| `name` | string | — | MUST include environment name (e.g., `backup-dev-id`) |
| `region` | string | `"fr-par"` | Scaleway region |
| `versioning_enabled` | bool | `true` | Once enabled, cannot be unversioned (only suspended) |
| `retention_days` | number | `365` | Days until current-version objects expire |
| `noncurrent_version_expiry_days` | number | `30` | Days until non-current object versions expire |
| `cold_storage_enabled` | bool | `true` | Toggle for GLACIER tier transition |
| `cold_storage_transition_days` | number | `90` | Days until transition to GLACIER storage class |
| `encryption` | string | `"AES256"` | Fixed; SSE-S3 via AES-256 |
| `force_destroy` | bool | `false` | Fixed; prevents accidental data loss via Terraform |

**Invariants:**
- `cold_storage_enabled = false` OR `cold_storage_transition_days < retention_days` (FR-016 — validated at plan time via Terraform `precondition`)
- `name` contains the environment name as a substring (convention, not mechanically enforced)
- `force_destroy` is always false (hardcoded; no tfvars override)
- `lifecycle.prevent_destroy = true` on the Terraform resource — bucket cannot be destroyed via `terraform destroy`

**State transitions (versioning):**
```
unversioned → versioning_enabled=true → versioned (irreversible)
versioned → versioning_enabled=false → suspended (data retained, no new versions)
```

---

### ScopedAccessIdentity

The Scaleway IAM application issued to backup workloads. Has object-level read/write access to the bucket but no administrative rights (no bucket deletion, no configuration changes).

| Field | Type | Notes |
|-------|------|-------|
| `name` | string | e.g., `backup-workload-dev` |
| `iam_permissions` | list(string) | `["ObjectStorageObjectsRead", "ObjectStorageObjectsWrite"]` |
| `access_key` | string | Public identifier; surfaced as Terraform output |
| `secret_key` | string | Sensitive; written to Infisical only, never output in plaintext |
| `infisical_path` | string | e.g., `/backup/dev/` |

**Invariants:**
- No `ObjectStorageBuckets*` permissions — identity has no bucket-level administrative rights
- `secret_key` MUST NOT appear in Terraform output (sensitive = true) or tfvars files

**Access verification (FR-011):**
| Action | Expected result |
|--------|----------------|
| `s3:PutObject` | Allow |
| `s3:GetObject` | Allow |
| `s3:DeleteBucket` | Deny (IAM has no bucket permission + bucket policy has no allow) |

---

### CIBucketPolicy

An S3-style bucket policy applied to `BackupBucket` that enforces FR-014: the CI provisioning identity cannot delete the bucket even though its IAM policy grants `ObjectStorageBucketsWrite`.

| Field | Type | Notes |
|-------|------|-------|
| `principal` | string | `application_id:<ci-app-uuid>` (the `github-ci` IAM application) |
| `effect` | string | `"Deny"` |
| `action` | list(string) | `["s3:DeleteBucket"]` |
| `resource` | list(string) | The bucket name |

**Why this is needed:** Scaleway's IAM does not have a "create/update bucket but not delete" permission set. The only mechanism to enforce a deletion prohibition for an identity that has `ObjectStorageBucketsWrite` is an explicit DENY in the S3 bucket policy. Per Scaleway IAM evaluation logic, explicit denies in bucket policies override IAM allows.

---

### LifecyclePolicy

Not a distinct Terraform resource — represented as a `lifecycle_rule` block within `scaleway_object_bucket`. Documented here as a logical entity.

| Rule | Condition | Action |
|------|-----------|--------|
| Current-version expiry | Always active when `enabled = true` | Expire objects after `retention_days` days |
| Noncurrent-version expiry | Always active when versioning enabled | Expire noncurrent versions after `noncurrent_version_expiry_days` days |
| Cold-tier transition | Active only when `cold_storage_enabled = true` | Transition to GLACIER after `cold_storage_transition_days` days |

All three rules share a single `lifecycle_rule` block with `id = "backup-retention"` and `enabled = true`.

---

## Cross-Entity Relationships

```
BackupBucket
  ├── has CIBucketPolicy (1:1) — enforces deletion deny for CI principal
  ├── has LifecyclePolicy (inline) — retention, expiry, cold tier rules
  └── has SSEConfiguration (1:1) — AES256 encryption

ScopedAccessIdentity
  └── IAM policy scoped to BackupBucket's project
      (no direct resource-level binding — Scaleway IAM is project-scoped)
```

---

## Validation Rules

| Rule ID | Entity | Condition | Error |
|---------|--------|-----------|-------|
| FR-016 | BackupBucket | `!cold_storage_enabled \|\| cold_storage_transition_days < retention_days` | `cold_storage_transition_days must be strictly less than retention_days` |
| FR-015 | BackupBucket | `name` contains env name | Convention (not enforced by Terraform; enforced by tfvars design) |
| FR-001 | BackupBucket | SSE resource always present | N/A — resource is unconditional |
| FR-007 | ScopedAccessIdentity | `secret_key` output marked `sensitive = true`; NOT in any tfvars file | N/A — enforced by Terraform output config |
