region     = "fr-par"
project_id = "6283c05b-a4c7-4f83-a75f-83adad236d54"

# Lifecycle defaults are accepted for dev:
#   retention_days                 = 365
#   noncurrent_version_expiry_days = 30
#   cold_storage_enabled           = true
#   cold_storage_transition_days   = 90

buckets = {
  backup = {
    bucket_name             = "backup-dev-id"
    identity_app_prefix     = "backup-k8s"
    identity_policy_prefix  = "backup-k8s-objects"
    identity_purpose        = "grants pods object read/write on the backup bucket"
    api_key_purpose         = "Backup workload credentials"
    api_key_consumer        = "Consumed via Infisical → ESO → Kubernetes Secret"
  }
  velero = {
    bucket_name             = "backup-velero-dev-id"
    identity_app_prefix     = "backup-velero-k8s"
    identity_policy_prefix  = "backup-velero-objects"
    identity_purpose        = "grants pods object read/write on the Velero backup bucket"
    api_key_purpose         = "Velero backup workload credentials"
    api_key_consumer        = "Consumed via OpenBao (kv/apps/velero/scaleway-s3-credentials) → ESO → Kubernetes Secret"
  }
}
