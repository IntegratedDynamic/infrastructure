# Terraform Interface Contract: 03-backup/scaleway

This document defines the public interface of the `03-backup/scaleway` Terraform root — the variables callers supply via `env/<workspace>.tfvars` and the outputs it produces.

---

## Input Variables

### Identity & Scope

| Variable | Type | Required | Default | Description |
|----------|------|----------|---------|-------------|
| `project_id` | string | Yes | — | Scaleway project the bucket and IAM resources belong to |
| `ci_application_id` | string | Yes | — | IAM application ID of the `github-ci` identity (for the bucket policy Deny statement). Stable after `01-iam/bootstrap/scaleway` is applied. |

### Bucket

| Variable | Type | Required | Default | Description |
|----------|------|----------|---------|-------------|
| `bucket_name` | string | Yes | — | Full bucket name. MUST include the environment name (e.g., `backup-dev-id`). |
| `region` | string | No | `"fr-par"` | Scaleway region where the bucket is created |

### Lifecycle

| Variable | Type | Required | Default | Description |
|----------|------|----------|---------|-------------|
| `versioning_enabled` | bool | No | `true` | Enable/suspend bucket versioning |
| `retention_days` | number | No | `365` | Days before current-version objects expire |
| `noncurrent_version_expiry_days` | number | No | `30` | Days before non-current versions expire |
| `cold_storage_enabled` | bool | No | `true` | Enable the GLACIER storage-class transition rule |
| `cold_storage_transition_days` | number | No | `90` | Days before objects transition to GLACIER (only evaluated when `cold_storage_enabled = true`) |

**Validation gate (FR-016):** If `cold_storage_enabled = true`, then `cold_storage_transition_days` MUST be strictly less than `retention_days`. Violation causes `terraform plan` to fail with an explicit error.

### Infisical (secret storage)

| Variable | Type | Required | Default | Description |
|----------|------|----------|---------|-------------|
| `infisical_workspace_id` | string | No | `"7ecb6ed4-058a-46cd-ac9f-7e792469cf0f"` | Infisical project ID for writing scoped credentials |
| `infisical_env_slug` | string | No | `"staging"` | Infisical environment slug |
| `infisical_folder_path` | string | No | `"/backup/dev"` | Infisical folder path for backup workload credentials |

### Infisical auth (local dev only)

| Variable | Type | Required | Default | Description |
|----------|------|----------|---------|-------------|
| `infisical_client_id` | string | No | `""` | Universal auth client ID (local dev only) |
| `infisical_client_secret` | string | No | `""` | Universal auth client secret (local dev only; sensitive) |

---

## Outputs

| Output | Type | Sensitive | Description |
|--------|------|-----------|-------------|
| `bucket_name` | string | No | Provisioned bucket name |
| `bucket_region` | string | No | Region the bucket was created in |
| `bucket_endpoint` | string | No | S3-compatible endpoint URL for the bucket |
| `workload_access_key` | string | No | Public access key for the scoped backup workload identity |

**Note:** The workload secret key is written to Infisical and is never surfaced as a Terraform output. It is never stored in tfvars files. State contains it as a sensitive value.

---

## Infisical Secret Outputs

The root writes two secrets to Infisical under `var.infisical_folder_path`:

| Secret name | Content |
|-------------|---------|
| `BACKUP_ACCESS_KEY` | SCW access key for the backup workload identity |
| `BACKUP_SECRET_KEY` | SCW secret key for the backup workload identity (sensitive) |

---

## Environment Files

| File | Workspace | Environment |
|------|-----------|-------------|
| `env/dev.tfvars` | `dev` | Development / homelab |

State key: `backup/scaleway/dev/terraform.tfstate` (in the shared S3 state bucket).

---

## CI Workflow Contract

| Trigger | Command |
|---------|---------|
| Pull request touching `03-backup/scaleway/**` | `plan` |
| Push to `main` touching `03-backup/scaleway/**` | `apply` |
| `workflow_dispatch` | `plan` or `apply` (no `destroy` option) |
| Scheduled event | **Never** (no cron, no destroy) |

The backup CI workflow has no `schedule:` trigger and no `destroy` command mapping, satisfying FR-013.

Post-apply step (on push to main only): `scw object bucket get <bucket_name>` — confirms the bucket exists. No S3 API property checks.
