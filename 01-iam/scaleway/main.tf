resource "scaleway_iam_application" "this" {
  name        = "github-ci"
  description = "GitHub Actions CI for the IntegratedDynamic/infrastructure repo (managed by terraform: github-ci/)."
}

# Dummy permission for the IAM Scaleway User. TBD
resource "scaleway_iam_policy" "this" {
  name           = "github-ci-object-storage-ro"
  description    = "Read-only Object Storage for the GitHub Actions CI application, project-scoped."
  application_id = scaleway_iam_application.this.id

  rule {
    project_ids          = [var.project_id]
    permission_set_names = ["VPCFullAccess", "KubernetesFullAccess", "PrivateNetworksFullAccess", "IPAMReadOnly"]
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
