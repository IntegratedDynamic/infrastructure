# Tasks: Backup Storage Foundation

**Input**: Design documents from `/specs/001-backup-s3-foundation/`

**Branch**: `001-backup-s3-foundation` | **Plan**: [plan.md](plan.md) | **Spec**: [spec.md](spec.md)

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies on incomplete tasks)
- **[Story]**: User story label (US1–US4)
- Tests: not requested — no test tasks generated

---

## Phase 1: Setup

**Purpose**: Create the new Terraform root's directory structure.

- [x] T001 Create directories `03-backup/scaleway/` and `03-backup/scaleway/env/`

---

## Phase 2: Foundational (Blocking Prerequisite)

**Purpose**: Extend the existing `github-ci` Scaleway identity with the permissions the backup CI workflow needs. Must be applied (or at least committed to trigger CI apply) before the backup root's workflow can run `plan` or `apply`.

**⚠️ CRITICAL**: The backup workflow will fail without this. Apply via the existing `iam_terraform-backend-role.yml` CI workflow or locally with admin Scaleway credentials.

- [x] T002 Update `01-iam/bootstrap/scaleway/main.tf` — add a second `scaleway_iam_policy` resource (e.g. `backup_ci`) attached to `scaleway_iam_application.this`, granting `ObjectStorageBucketsRead`, `ObjectStorageBucketsWrite`, `ObjectStorageObjectsRead`, `ObjectStorageObjectsWrite`, and IAM management permissions (`IamReadOnly` + `IamManager` or equivalent) scoped to `var.project_id`

**Checkpoint**: `01-iam/bootstrap/scaleway` applied → `github-ci` has Object Storage + IAM permissions → backup root CI can proceed.

---

## Phase 3: User Story 1 — Persistent Backup Bucket (Priority: P1) 🎯 MVP

**Goal**: Provision an encrypted, versioned bucket in its own Terraform root with state completely independent from the cluster. Cluster destroy/apply cycles cannot touch it.

**Independent Test**: `scw object bucket get backup-dev-id --region fr-par` returns bucket metadata after `terraform apply`. Run `terraform destroy -target=module.*cluster*` and confirm the bucket still exists.

- [x] T003 [US1] Create `03-backup/scaleway/version.tf` — S3 backend (`bucket`, `region="eu-west-3"`, `workspace_key_prefix="backup/scaleway"`, `key="terraform.tfstate"`, `encrypt=true`, `use_lockfile=true`) + `required_providers`: scaleway `~>2.0`, infisical `~>0.16`, time `~>0.12`; `provider "scaleway" {}` + `provider "infisical" { auth = { oidc = {} } }` (matching pattern of `02-cluster/scaleway/version.tf`)

- [x] T004 [P] [US1] Create `03-backup/scaleway/variables.tf` — declare ALL variables with sane defaults:
  - Bucket: `bucket_name` (string, required), `region` (default `"fr-par"`)
  - Lifecycle: `versioning_enabled` (bool, default `true`), `retention_days` (number, default `365`), `noncurrent_version_expiry_days` (number, default `30`), `cold_storage_enabled` (bool, default `true`), `cold_storage_transition_days` (number, default `90`)
  - Identity: `project_id` (string, required), `ci_application_id` (string, required — the `github-ci` app ID from `01-iam/bootstrap/scaleway` outputs)
  - Infisical: `infisical_workspace_id` (default `"7ecb6ed4-058a-46cd-ac9f-7e792469cf0f"`), `infisical_env_slug` (default `"staging"`), `infisical_folder_path` (default `"/backup/dev"`), `infisical_client_id` (default `""`), `infisical_client_secret` (sensitive, default `""`)

- [x] T005 [P] [US1] Create `03-backup/scaleway/env/dev.tfvars` — fill dev workspace values: `bucket_name = "backup-dev-id"`, `region = "fr-par"`, `project_id = "<same project_id as 01-iam/bootstrap/scaleway>"`, `ci_application_id = "<application_id output from 01-iam/bootstrap/scaleway state>"` (retrieve via `terraform -chdir=01-iam/bootstrap/scaleway output application_id`), infisical defaults accepted

- [x] T006 [US1] Create `03-backup/scaleway/main.tf` — two resources:
  1. `scaleway_object_bucket "backup"`: `name=var.bucket_name`, `region=var.region`, `versioning { enabled=var.versioning_enabled }`, `lifecycle { prevent_destroy=true; precondition { condition = !var.cold_storage_enabled || var.cold_storage_transition_days < var.retention_days; error_message = "cold_storage_transition_days must be strictly less than retention_days" } }`. Add comment at the `force_destroy` absence: `# Deletion intentionally NOT protected at the provider level — see spec.md FR-014. Bucket deletion is a manual-only, human-operator action.`
  2. `scaleway_object_bucket_server_side_encryption_configuration "backup"`: `bucket=scaleway_object_bucket.backup.name`, `region=var.region`, `rule { apply_server_side_encryption_by_default { sse_algorithm="AES256" } }`

- [x] T007 [P] [US1] Create `03-backup/scaleway/outputs.tf` — three outputs: `bucket_name` (value=`scaleway_object_bucket.backup.name`), `bucket_region` (value=`scaleway_object_bucket.backup.region`), `bucket_endpoint` (value=`"https://s3.${var.region}.scw.cloud/${var.bucket_name}"`)

- [x] T008 [US1] Add `03-backup/scaleway` to `mise.toml` lock task (add `terraform -chdir=03-backup/scaleway providers lock -platform=darwin_arm64 -platform=linux_amd64` alongside the other roots), then run `mise run lock` to generate `03-backup/scaleway/.terraform.lock.hcl`

**Checkpoint**: `terraform apply -var-file=env/dev.tfvars` succeeds. `scw object bucket get backup-dev-id --region fr-par` returns bucket metadata. ✅ US1 done.

---

## Phase 4: User Story 2 — Configurable Data Retention (Priority: P2)

**Goal**: Complete the lifecycle_rule block so all four lifecycle parameters (retention, noncurrent expiry, cold storage toggle + delay) are driven by `dev.tfvars` with no hardcoded values.

**Independent Test**: Modify `dev.tfvars` to set `cold_storage_enabled=true`, `cold_storage_transition_days=30`, `retention_days=365`. Re-apply. Confirm lifecycle rule changes (manual check sufficient — see quickstart.md). Then test the FR-016 gate: set `cold_storage_transition_days=365` and confirm plan fails with the precondition error.

- [x] T009 [US2] Update `03-backup/scaleway/main.tf` — expand the `lifecycle_rule` block inside `scaleway_object_bucket.backup`:
  - Add `id = "backup-retention"`, `enabled = true`
  - Add `expiration { days = var.retention_days }`
  - Add `noncurrent_version_expiration { noncurrent_days = var.noncurrent_version_expiry_days }`
  - Add `dynamic "transition" { for_each = var.cold_storage_enabled ? [var.cold_storage_transition_days] : []; content { days = transition.value; storage_class = "GLACIER" } }`
  - The FR-016 precondition is already present from T006 — no change needed

**Checkpoint**: `terraform plan` with `cold_storage_transition_days=365` + `retention_days=365` fails with precondition error. Plan with valid values shows correct lifecycle rules in the diff. ✅ US2 done.

---

## Phase 5: User Story 3 — Scoped Backup Credentials (Priority: P3)

**Goal**: Provision a Scaleway IAM application with object-level read+write access (no bucket deletion), write its credentials to Infisical, and attach a bucket policy that explicitly denies `s3:DeleteBucket` to the CI identity.

**Independent Test**: Run quickstart.md §"Valider l'accès workload depuis le cluster" — create the test Secret manually from Terraform outputs, launch `test-job.yaml`, verify the Job succeeds. Confirm `workload_access_key` appears in `terraform output`.

- [x] T010 [US3] Create `03-backup/scaleway/iam.tf` — three resources:
  1. `scaleway_iam_application "workload"`: `name = "backup-workload-${terraform.workspace}"`
  2. `scaleway_iam_policy "workload"`: `application_id = scaleway_iam_application.workload.id`, `rule { project_ids = [var.project_id]; permission_set_names = ["ObjectStorageObjectsRead", "ObjectStorageObjectsWrite"] }`
  3. `time_rotating "workload_key"`: `rotation_days = 365`; `scaleway_iam_api_key "workload"`: `application_id = scaleway_iam_application.workload.id`, `expires_at = time_rotating.workload_key.rotation_rfc3339`, `default_project_id = var.project_id`

- [x] T011 [US3] Create `03-backup/scaleway/policy.tf` — `scaleway_object_bucket_policy "backup"`: `bucket = scaleway_object_bucket.backup.name`, `region = var.region`, `policy = jsonencode({ Version = "2023-04-17"; Statement = [{ Sid = "DenyBucketDeletionForCI"; Effect = "Deny"; Principal = { SCW = "application_id:${var.ci_application_id}" }; Action = ["s3:DeleteBucket"]; Resource = [scaleway_object_bucket.backup.name] }] })`

- [x] T012 [P] [US3] Create `03-backup/scaleway/infisical.tf` — `infisical_secret_folder "backup"` at path `var.infisical_folder_path` under root `/`, then `infisical_secret "access_key"` (`name = "BACKUP_ACCESS_KEY"`, `value = scaleway_iam_api_key.workload.access_key`) and `infisical_secret "secret_key"` (`name = "BACKUP_SECRET_KEY"`, `value = scaleway_iam_api_key.workload.secret_key`, sensitive). Follow the pattern in `01-iam/bootstrap/scaleway/main.tf`.

- [x] T013 [US3] Update `03-backup/scaleway/outputs.tf` — add `workload_access_key` output: `value = scaleway_iam_api_key.workload.access_key`, `description = "Public access key for the scoped backup workload identity."`

**Checkpoint**: `terraform apply` succeeds with 5+ new resources. `terraform output workload_access_key` shows an access key. Infisical `/backup/dev/` folder contains `BACKUP_ACCESS_KEY` and `BACKUP_SECRET_KEY`. ✅ US3 done.

---

## Phase 6: User Story 4 — CI Workflow (Priority: P4)

**Goal**: A CI workflow that runs `plan` on PRs and `apply` on push to main, with no scheduled destroy, and a post-apply bucket existence check.

**Independent Test**: Open a PR touching `03-backup/scaleway/**` and confirm the workflow runs `plan`. Merge and confirm `apply` runs. Confirm no `schedule:` trigger exists in the file.

- [x] T014 [US4] Create `.github/workflows/backup_scaleway.yml` — model after `scaleway.yml` with these differences: `on.push.paths` and `on.pull_request.paths` targeting `03-backup/scaleway/**` and the workflow file itself; `on.workflow_dispatch.inputs.command` options `[plan, apply]` only (no `destroy`); `Resolve terraform command` step maps `push → apply`, else `plan` (no `schedule` case, no `destroy`); composite action call with `root: 03-backup/scaleway`, `tfvars-file: dev.tfvars`; `concurrency.group: backup-scaleway-${{ github.ref }}`; same `environment: scaleway`, `permissions`, `env:` block as `scaleway.yml`

- [x] T015 [US4] Update `.github/workflows/backup_scaleway.yml` — add a final step after the composite action, conditioned on `steps.cmd.outputs.command == 'apply'`: run `scw object bucket get ${{ env.BUCKET_NAME }} --region fr-par` where `BUCKET_NAME` is a job-level env var set from `dev.tfvars`'s bucket name (hardcode `backup-dev-id` as a workflow env var)

**Checkpoint**: Workflow file passes `actionlint`. PR triggers plan job. Push to main triggers apply + post-apply bucket check. ✅ US4 done.

---

## Phase 7: Polish & Cross-Cutting Concerns

- [x] T016 Run `actionlint .github/workflows/backup_scaleway.yml` and fix any issues
- [x] T017 [P] Verify `03-backup/scaleway/.terraform.lock.hcl` covers both `linux_amd64` and `darwin_arm64` platforms (inspect the file — each provider entry should have hashes for both)
- [x] T018 [P] Add a comment in `01-iam/bootstrap/scaleway/main.tf` above the new policy resource explaining it was added for the backup domain CI workflow (referencing `03-backup/scaleway/`)
- [ ] T019 Run quickstart.md local validation (bucket existence check + test-job.yaml Job) against the dev environment

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — start immediately
- **Foundational (Phase 2)**: Depends on Phase 1 — **blocks CI apply of Phase 3+** (not local dev)
- **US1 (Phase 3)**: Depends on Phase 1; needs Phase 2 applied for CI; can be developed locally without it
- **US2 (Phase 4)**: Depends on US1 (Phase 3) — expands `main.tf`
- **US3 (Phase 5)**: Depends on US1 (Phase 3) — new files `iam.tf`, `policy.tf`, `infisical.tf`; US2 can be done in parallel with US3
- **US4 (Phase 6)**: Depends on US1 (bucket name known) — can be written in parallel with US2/US3
- **Polish (Phase 7)**: Depends on all phases complete

### User Story Dependencies

```
Phase 2 (IAM permissions) ──► must be applied before CI can run Phase 3+
Phase 3 (US1) ──► bucket exists
  ├──► Phase 4 (US2): lifecycle rules complete
  ├──► Phase 5 (US3): credentials + policy (parallel with US2)
  └──► Phase 6 (US4): CI workflow (parallel with US2 + US3)
```

### Within Each Phase

- T004, T005: parallel with each other and with T003 (different files)
- T010, T011, T012: T010 and T012 can be written in parallel (different files); T011 depends on knowing `ci_application_id` (from T005/dev.tfvars)
- T014, T015: T015 extends T014 — sequential

---

## Parallel Execution Examples

```bash
# Phase 3 — write all files in parallel (different files, no conflict):
Task T003: version.tf
Task T004: variables.tf      # parallel
Task T005: env/dev.tfvars    # parallel
# Then:
Task T006: main.tf           # after T004 (variable names needed)
Task T007: outputs.tf        # parallel with T006

# Phase 5 — partially parallel:
Task T010: iam.tf
Task T012: infisical.tf      # parallel with T010
# Then:
Task T011: policy.tf         # after T010 (references scaleway_iam_api_key not needed but ci_application_id from T005 needed)
Task T013: outputs.tf        # after T010
```

---

## Implementation Strategy

### MVP (User Story 1 only)

1. T001 → T002 → T003 + T004 + T005 (parallel) → T006 → T007 → T008
2. Apply locally: `terraform -chdir=03-backup/scaleway apply -var-file=env/dev.tfvars`
3. Validate: `scw object bucket get backup-dev-id --region fr-par`
4. **STOP and validate** — bucket exists independently ✅

### Incremental Delivery

1. MVP (US1) → bucket exists
2. US2 → lifecycle is configurable; FR-016 gate works
3. US3 → workload credentials provisioned; local Job test passes
4. US4 → CI workflow running; post-apply check automated

### Single Developer

Work sequentially: US1 → US2 → US3 → US4 → Polish. Total ~17 tasks, mostly file creation.

---

## Notes

- `ci_application_id` in `env/dev.tfvars` must be fetched from the existing state of `01-iam/bootstrap/scaleway`: `terraform -chdir=01-iam/bootstrap/scaleway output application_id`
- T002 is **non-blocking for local development** — you can apply `03-backup/scaleway` locally with admin Scaleway credentials before T002 is applied. It becomes blocking when the CI workflow runs.
- The `scaleway_iam_api_key` for the workload has a 365-day rotation via `time_rotating` — same pattern as the cluster CI key in `01-iam/bootstrap/scaleway`
- `test-job.yaml` in `specs/001-backup-s3-foundation/` is a manual test fixture, not part of the Terraform root
