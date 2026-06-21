# Feature Specification: Backup Storage Foundation

**Feature Branch**: `001-backup-s3-foundation`

**Created**: 2026-06-20

**Status**: Draft

**Input**: User description: "Fondation backup S3 (Scaleway Object Storage) — root Terraform dédié, état isolé, bucket chiffré + versionné, configurable, credentials scoped, workflow CI sans destroy."

## Clarifications

### Session 2026-06-20

- Q: Should the bucket have provider-level deletion protection? → A: No provider-level protection. Bucket deletion is reserved for human operators with administrative credentials; the CI identity SHALL NOT have bucket deletion rights. The implementation code SHALL include a comment at the point where deletion protection is absent, documenting this deliberate choice.
- Q: Which environments are in scope for the initial delivery? → A: Single `dev` environment only. Additional environments (e.g., `prod`) are out of scope and can be added via a new environment configuration file without modifying shared infrastructure code.
- Q: Is operational observability (monitoring, alerting) in scope? → A: No. Bucket-level observability is deferred to a future platform observability feature. CI verification at deploy time is the only correctness signal required.
- Q: Is a bucket naming convention required to prevent collisions across environments? → A: Yes. The bucket name SHALL include the environment name as a component (e.g., `backup-dev-<project>`). This is a platform requirement, not an operator preference.
- Q: Should the platform validate conflicting lifecycle values (cold storage transition delay ≥ object retention period)? → A: Yes, as a temporary safety net until a future lifecycle policy operator is implemented. The platform SHALL reject configurations where the cold storage transition delay is greater than or equal to the object retention period. This validation is explicitly transitional.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Persistent Backup Bucket (Priority: P1)

A platform operator provisions a backup storage bucket that is completely independent from the cluster lifecycle. The bucket persists through cluster destroy and re-apply cycles — cluster teardowns never affect it.

**Why this priority**: Without isolation from the cluster lifecycle, backup data would be destroyed every night when the scheduled cluster teardown runs, defeating the entire purpose of backups.

**Independent Test**: Can be tested by provisioning the bucket, writing a marker object, triggering a full cluster destroy/apply cycle, and confirming the marker object still exists.

**Acceptance Scenarios**:

1. **Given** the backup bucket has been provisioned and contains a marker object, **When** the cluster is fully destroyed and re-applied, **Then** the marker object is still present in the bucket.
2. **Given** the backup bucket infrastructure has been applied, **When** the cluster infrastructure is destroyed, **Then** no dependency causes the backup bucket to be deleted or modified.

---

### User Story 2 - Configurable Data Retention (Priority: P2)

A platform operator can adjust the bucket's data lifecycle policies (object retention, noncurrent version expiry, cold storage tier transition) per environment through an environment configuration file, without modifying shared infrastructure code.

**Why this priority**: Different environments have different cost/durability tradeoffs. A dev environment might keep objects for 30 days; production might keep them for a year. These values must be externalizable, never hardcoded.

**Independent Test**: Can be tested by deploying the bucket with a non-default environment configuration file and asserting via the cloud provider CLI that the applied lifecycle rules match the file's values exactly.

**Acceptance Scenarios**:

1. **Given** an environment configuration file specifies a 90-day object retention and cold storage tier transition disabled, **When** the bucket is provisioned using that configuration, **Then** the bucket's lifecycle policy reflects exactly those settings.
2. **Given** no environment configuration overrides are provided, **When** the bucket is provisioned with default settings, **Then** the defaults (365-day retention, 30-day noncurrent version expiry, 90-day cold storage tier transition enabled, versioning on) are applied without any required operator input.
3. **Given** the bucket is already provisioned, **When** the operator updates the environment configuration file and re-applies, **Then** the lifecycle policy updates to match the new values.

---

### User Story 3 - Scoped Backup Credentials (Priority: P3)

Backup workloads are issued credentials that allow reading and writing backup objects but cannot perform administrative actions (deleting the bucket, modifying bucket configuration, etc.).

**Why this priority**: Principle of least privilege — a compromised backup agent must not be able to destroy the backup bucket. Credential scope is a security boundary, not an afterthought.

**Independent Test**: Can be tested by using the issued credentials to attempt a write, a read, and a bucket deletion — verifying the first two succeed and the third is denied with an access error.

**Acceptance Scenarios**:

1. **Given** scoped credentials have been issued, **When** a backup workload writes an object using those credentials, **Then** the write succeeds.
2. **Given** scoped credentials have been issued, **When** a backup workload reads a previously written object using those credentials, **Then** the read succeeds.
3. **Given** scoped credentials have been issued, **When** a process attempts to delete the bucket using those credentials, **Then** the operation is denied with an access error.

---

### User Story 4 - Automated CI Verification (Priority: P4)

Every deployment of the backup bucket is automatically verified end-to-end by the CI pipeline, with no manual steps required. Verification covers encryption, versioning, lifecycle accuracy, credential scope, and cluster-lifecycle isolation.

**Why this priority**: Manual verification is error-prone and not repeatable. The acceptance criteria require CI-based proof that can be executed and re-executed by any contributor.

**Independent Test**: Can be tested by running the CI verification job on a feature branch and observing that all four verification assertions pass without human intervention.

**Acceptance Scenarios**:

1. **Given** the CI job runs after provisioning, **When** it inspects the bucket, **Then** it confirms the bucket exists with encryption and versioning enabled.
2. **Given** the CI job runs, **When** it reads the bucket's lifecycle configuration, **Then** it confirms the rules match the values declared in the environment configuration file used during provisioning.
3. **Given** the CI job runs with the scoped credentials, **When** it attempts a write, a read, and a bucket deletion, **Then** write and read succeed, and bucket deletion is denied.
4. **Given** the CI job runs after a cluster destroy/apply cycle, **When** it checks for a pre-written marker object, **Then** the object is still present.

---

### Edge Cases

- ~~What happens when the cold storage tier transition delay is set shorter than the noncurrent version expiry window?~~ Resolved: the platform SHALL reject configurations where the cold storage transition delay ≥ object retention period (FR-016). This validation is a temporary safety net pending a future lifecycle policy operator.
- ~~How does the system behave if the bucket name collides with an existing bucket in the same account?~~ Resolved: bucket name SHALL include the environment name, making collisions a convention violation rather than an operational risk.
- What happens to objects already in standard storage when the cold storage tier transition is toggled from disabled to enabled on an existing bucket?
- How are leaked scoped credentials revoked without disrupting the bucket or its data?
- What happens if the CI verification job runs while the bucket is being provisioned (race condition)?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The platform SHALL provision an object storage bucket with server-side encryption enabled.
- **FR-002**: The platform SHALL enable versioning on the bucket by default, with versioning configurable (on/off) via an environment configuration file.
- **FR-003**: The platform SHALL apply a configurable object retention policy (maximum age before expiry) to the bucket, with a default of 365 days.
- **FR-004**: The platform SHALL apply a configurable noncurrent version expiry policy, with a default of 30 days.
- **FR-005**: The platform SHALL support a configurable cold storage tier transition rule, with an on/off toggle and a transition delay in days, defaulting to enabled at 90 days.
- **FR-006**: The platform SHALL issue a scoped access identity with read and write permissions on the bucket's objects, and no administrative permissions (no bucket deletion, no bucket configuration changes).
- **FR-007**: The platform SHALL expose the scoped credentials as protected outputs, not stored in plaintext configuration files.
- **FR-015**: The backup bucket name SHALL include the environment name as a component (e.g., `backup-dev-<project>`), ensuring names are unique across environments by convention.
- **FR-016**: The platform SHALL reject configurations where the cold storage tier transition delay is greater than or equal to the object retention period, producing an explicit validation error. This is a temporary safety net pending a future lifecycle policy operator.
- **FR-014**: The CI identity used by the backup CI workflow SHALL NOT have bucket deletion rights. Bucket deletion SHALL be possible only by a human operator acting with administrative credentials outside of any automated pipeline.
- **FR-008**: The backup bucket's provisioning lifecycle SHALL be fully independent from the cluster's provisioning lifecycle — destroying the cluster SHALL NOT affect the bucket.
- **FR-009**: The CI pipeline SHALL verify after each deployment that the bucket's encryption and versioning are enabled.
- **FR-010**: The CI pipeline SHALL verify after each deployment that the bucket's lifecycle rules match the values declared in the environment configuration file.
- **FR-011**: The CI pipeline SHALL verify that the scoped credentials can write and read objects but cannot delete the bucket.
- **FR-012**: The CI pipeline SHALL verify that a pre-written marker object persists through a full cluster destroy/apply cycle.
- **FR-013**: The platform SHALL provide a dedicated CI workflow for the backup domain that runs plan on pull requests and apply on merge to main, with no scheduled destroy ever configured.

### Key Entities

- **Backup Bucket**: The object storage container. Attributes: name, region, encryption status, versioning status.
- **Lifecycle Policy**: Data retention rules attached to the bucket. Attributes: object retention period (days), noncurrent version expiry period (days), cold storage tier transition toggle (enabled/disabled), cold storage tier transition delay (days).
- **Scoped Access Identity**: The access identity issued to backup workloads. Attributes: permission scope (read/write objects only, no administrative rights), credential outputs (protected/sensitive).
- **Backup Infrastructure Domain**: The isolated infrastructure unit managing the bucket and its credentials. Attribute: independent state lifecycle from all other infrastructure domains.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: The backup bucket retains 100% of its stored objects through every cluster destroy/apply cycle, verified on at least one complete cycle before merge to main.
- **SC-002**: 100% of configurable lifecycle parameters (retention, noncurrent expiry, cold storage tier toggle and delay) are reflected exactly in the provisioned bucket, with zero hardcoded values in shared infrastructure code.
- **SC-003**: Scoped credentials produce a successful write and a successful read, and an explicit access denial on bucket deletion, in 100% of CI verification runs.
- **SC-004**: All four CI verification assertions (encryption + versioning, lifecycle accuracy, credential scope, cluster isolation) pass on every deployment without any manual operator steps.
- **SC-005**: The backup CI workflow executes plan on every pull request and apply on every merge to main, with zero occurrences of a destroy step triggered by a scheduled event.

## Assumptions

- The backup bucket will be hosted in the same cloud provider region as the cluster unless overridden by the environment configuration file.
- Credential rotation and propagation to consuming workloads (e.g., via a secrets manager) is out of scope for this feature; this feature provisions and outputs the initial credentials only.
- The cold storage tier is the only tiered storage class in scope; additional storage tiers are out of scope.
- The bucket name is defined in the environment configuration file, not auto-generated at provisioning time.
- The initial delivery provisions a single `dev` environment. The workspace model allows adding further environments (e.g., `prod`) without code changes, but they are out of scope here.
- A single scoped access identity (one credential pair) per environment is sufficient; per-workload or multi-identity credential management is out of scope.
- The CI verification job uses the cloud provider CLI already available in the CI environment; no new tooling is introduced.
- The scoped identity has no path to escalating its own permissions (no IAM self-modification rights).
- No provider-level deletion protection is applied to the bucket; this is intentional and SHALL be documented via a code comment at the relevant point of implementation. Bucket deletion is a manual-only, human-operator action.
- Operational observability (monitoring, alerting) is out of scope for this feature; CI verification at deploy time is the only required correctness signal.
- The cross-rule lifecycle validation (FR-016) is explicitly temporary; a future lifecycle policy operator will supersede it with richer guardrails. The spec requirement is scoped to the transition delay vs. retention period constraint only.
