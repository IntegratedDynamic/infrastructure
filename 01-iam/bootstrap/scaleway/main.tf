resource "scaleway_iam_application" "this" {
  name        = "github-ci"
  description = "GitHub Actions CI for the IntegratedDynamic/infrastructure repo (managed by terraform: github-ci/)."
}

# Lets CI manage the Kapsule cluster end-to-end (create/destroy): the K8s cluster
# itself plus its VPC + private network + IPAM lookups. Project-scoped.
resource "scaleway_iam_policy" "this" {
  name           = "github-ci-cluster-management"
  description    = "Kubernetes/VPC/PrivateNetwork management for the GitHub Actions CI application, project-scoped."
  application_id = scaleway_iam_application.this.id

  rule {
    project_ids          = [var.project_id]
    permission_set_names = ["VPCFullAccess", "KubernetesFullAccess", "PrivateNetworksFullAccess", "IPAMReadOnly"]
  }
}

# Added for 03-backup/scaleway: the backup CI workflow runs under the same
# github-ci identity and needs Object Storage management + IAM application/policy/
# API key management to provision the bucket and scoped workload credentials.
# Bucket deletion is blocked via prevent_destroy + absence of a destroy trigger
# in the CI workflow (Scaleway bucket policies do not support s3:DeleteBucket).
resource "scaleway_iam_policy" "backup_ci" {
  name           = "github-ci-backup-management"
  description    = "Object Storage bucket + IAM workload identity management for the backup domain CI workflow (03-backup/scaleway/)."
  application_id = scaleway_iam_application.this.id

  rule {
    project_ids = [var.project_id]
    permission_set_names = [
      "ObjectStorageBucketsRead",
      "ObjectStorageBucketsWrite",
      "ObjectStorageObjectsRead",
      "ObjectStorageObjectsWrite",
    ]
  }

  # IAM permission sets are organization-scoped — they cannot be combined
  # with project_ids in the same rule.
  rule {
    organization_id = var.organization_id
    permission_set_names = [
      # Required to create/manage the scoped workload IAM application, policy,
      # and API key in 03-backup/scaleway/iam.tf.
      "IAMApplicationManager",
      "IAMPolicyManager",
    ]
  }
}

# The org enforces an expiry on every API key, and `expires_at` is ForceNew, so
# the key inherently rotates when the expiry moves. time_rotating makes that
# concrete and self-renewing: the timestamp holds steady until the window
# elapses, then the next apply pushes it forward and rotates the key (re-run
# `gh secret set` afterwards — see README).
resource "time_rotating" "api_key" {
  rotation_days = var.api_key_rotation_days
}

resource "scaleway_iam_api_key" "this" {
  application_id = scaleway_iam_application.this.id
  description    = "Consumed from GitHub Actions secrets (SCW_ACCESS_KEY / SCW_SECRET_KEY)."

  # Bakes the project into the key so `scw object bucket list` resolves the right
  # scope without the workflow passing a project ID.
  default_project_id = var.project_id

  expires_at = time_rotating.api_key.rotation_rfc3339
}

# ── Write the key into Infisical ────────────────────────────────────────────
# GitHub secrets themselves are still set manually via `gh secret set` (see
# README) — automating that push is deferred to avoid a GitHub token here.

# infisical_secret does not create missing folders, so the CI folder must exist
# first. var.infisical_folder_path is "/<name>"; create that name under root.
resource "infisical_secret_folder" "ci" {
  project_id       = var.infisical_workspace_id
  environment_slug = var.infisical_env_slug
  folder_path      = "/"
  name             = trimprefix(var.infisical_folder_path, "/")
  description      = "CI secrets for GitHub Actions (managed by terraform: github-ci/)."
}

resource "infisical_secret" "scw_access_key" {
  name         = "SCW_ACCESS_KEY"
  value        = scaleway_iam_api_key.this.access_key
  env_slug     = var.infisical_env_slug
  workspace_id = var.infisical_workspace_id
  folder_path  = infisical_secret_folder.ci.path
}

resource "infisical_secret" "scw_secret_key" {
  name         = "SCW_SECRET_KEY"
  value        = scaleway_iam_api_key.this.secret_key
  env_slug     = var.infisical_env_slug
  workspace_id = var.infisical_workspace_id
  folder_path  = infisical_secret_folder.ci.path
}
