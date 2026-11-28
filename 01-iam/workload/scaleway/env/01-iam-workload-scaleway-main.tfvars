project_id = "6283c05b-a4c7-4f83-a75f-83adad236d54"

identities = {
  # The state credentials of every Crossplane Workspace (OpenBao, then ESO).
  # Unlike every other identity in this repo, this one's key leaves the admin's
  # own machine: a dedicated workload identity for that reason alone, not reused
  # from any state bucket's own identity.
  #
  # Project-scoped rule only, same as every other identity in this repo —
  # NOT also gated by a scaleway_object_bucket_policy per bucket. That was
  # tried (2026-08-19) and reverted: on Scaleway, attaching ANY bucket
  # policy stops being additive to IAM the way it is on AWS S3 — it
  # becomes the bucket's sole source of authorization, so every principal
  # not explicitly listed loses access, including the project admin's own
  # broad-scoped credentials. Confirmed live: it locked the admin session
  # itself out of all 8 buckets mid-apply (one of them being this very
  # root's own state backend, which is how the apply's own state write
  # failed). Real per-bucket least-privilege isn't available on this
  # platform for a bucket already relied on by other identities' implicit
  # project-wide access — project-scoped IAM, like every other identity
  # here, is the only viable option.
  #
  # purpose/policy_description kept short on purpose: Scaleway caps IAM
  # application/policy descriptions at 200 runes total, prefix included
  # (confirmed live — a longer purpose string here hit exactly that error
  # on apply).
  crossplane-state = {
    purpose            = "reads/writes the Terraform state buckets for the Crossplane Workspaces"
    policy_description = "Object Storage read/write, project-scoped (Scaleway IAM has no bucket-level rule field)."
    rules = [
      {
        project_ids          = ["6283c05b-a4c7-4f83-a75f-83adad236d54"]
        permission_set_names = ["ObjectStorageObjectsRead", "ObjectStorageObjectsWrite", "ObjectStorageBucketsRead", "ObjectStorageObjectsDelete"]
      }
    ]
  }
}

# api_key_rotation_days defaults to 365
