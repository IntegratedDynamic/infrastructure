resource "scaleway_iam_application" "workload" {
  name        = "backup-workload-${terraform.workspace}"
  description = "Backup workload identity for ${terraform.workspace} — object read/write on the backup bucket, no administrative rights (managed by terraform: 03-backup/scaleway/)."
}

resource "scaleway_iam_policy" "workload" {
  name           = "backup-workload-objects-${terraform.workspace}"
  description    = "Object-level read/write on the backup project. No bucket-level permissions — cannot delete or reconfigure the bucket."
  application_id = scaleway_iam_application.workload.id

  rule {
    project_ids          = [var.project_id]
    permission_set_names = ["ObjectStorageObjectsRead", "ObjectStorageObjectsWrite"]
  }
}

# Scaleway requires every API key to carry an expiry. time_rotating keeps
# the expiry self-renewing: once the window elapses, the next apply rotates
# the key. Update the Kubernetes Secret (via ESO re-sync) after each rotation.
resource "time_rotating" "workload_key" {
  rotation_days = 365
}

resource "scaleway_iam_api_key" "workload" {
  application_id     = scaleway_iam_application.workload.id
  description        = "Backup workload credentials for ${terraform.workspace}. Consumed via Infisical → ESO → Kubernetes Secret."
  default_project_id = var.project_id
  expires_at         = time_rotating.workload_key.rotation_rfc3339
}
