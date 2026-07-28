resource "scaleway_iam_application" "kubernetes" {
  name        = "backup-k8s-${terraform.workspace}"
  description = "Kubernetes workload identity for ${terraform.workspace} — grants pods object read/write on the backup bucket."
}

resource "scaleway_iam_policy" "kubernetes" {
  name           = "backup-k8s-objects-${terraform.workspace}"
  description    = "Object-level read/write on the backup project. No bucket-level permissions — cannot delete or reconfigure the bucket."
  application_id = scaleway_iam_application.kubernetes.id

  rule {
    project_ids          = [var.project_id]
    permission_set_names = ["ObjectStorageObjectsRead", "ObjectStorageObjectsWrite", "ObjectStorageBucketsRead", "ObjectStorageObjectsDelete"]
  }
}

# Scaleway requires every API key to carry an expiry. time_rotating keeps
# the expiry self-renewing: once the window elapses, the next apply rotates
# the key. Update the Kubernetes Secret (via ESO re-sync) after each rotation.
resource "time_rotating" "kubernetes_key" {
  rotation_days = 365
}

resource "scaleway_iam_api_key" "kubernetes" {
  application_id     = scaleway_iam_application.kubernetes.id
  description        = "Backup workload credentials for ${terraform.workspace}. Consumed via Infisical → ESO → Kubernetes Secret."
  default_project_id = var.project_id
  expires_at         = time_rotating.kubernetes_key.rotation_rfc3339
}

# Velero's own workload identity — a separate key from the OpenBao one above,
# even though the permission set is identical (Scaleway's IAM can't scope
# Object Storage below project level, so there's no tighter policy to write).
# The isolation that actually matters is the separate bucket in main.tf.
resource "scaleway_iam_application" "velero" {
  name        = "backup-velero-k8s-${terraform.workspace}"
  description = "Kubernetes workload identity for Velero on ${terraform.workspace} — grants pods object read/write on the Velero backup bucket."
}

resource "scaleway_iam_policy" "velero" {
  name           = "backup-velero-objects-${terraform.workspace}"
  description    = "Object-level read/write on the backup project. No bucket-level permissions — cannot delete or reconfigure a bucket."
  application_id = scaleway_iam_application.velero.id

  rule {
    project_ids          = [var.project_id]
    permission_set_names = ["ObjectStorageObjectsRead", "ObjectStorageObjectsWrite", "ObjectStorageBucketsRead", "ObjectStorageObjectsDelete"]
  }
}

resource "time_rotating" "velero_key" {
  rotation_days = 365
}

resource "scaleway_iam_api_key" "velero" {
  application_id     = scaleway_iam_application.velero.id
  description        = "Velero backup workload credentials for ${terraform.workspace}. Consumed via OpenBao (kv/apps/velero/scaleway-s3-credentials) → ESO → Kubernetes Secret."
  default_project_id = var.project_id
  expires_at         = time_rotating.velero_key.rotation_rfc3339
}
