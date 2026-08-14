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
  thanos = {
    bucket_name             = "monitoring-thanos-dev-id"
    identity_app_prefix     = "monitoring-thanos-k8s"
    identity_policy_prefix  = "monitoring-thanos-objects"
    identity_purpose        = "grants the Prometheus Thanos sidecar object read/write for TSDB block storage"
    api_key_purpose         = "Thanos sidecar object-storage credentials"
    api_key_consumer        = "Consumed via OpenBao (kv/apps/monitoring/thanos-scaleway-s3-credentials) → ESO → Kubernetes Secret"

    # Short-lived on purpose: this is near-term durability for Prometheus's
    # own TSDB blocks, not long-term queryable history — no Thanos
    # Query/Store Gateway reads this bucket (yet). No need for
    # backup/velero's versioning + 365d + GLACIER treatment; objects just
    # expire and are gone, which is the point (no volume needed, cost
    # savings). cold_storage_enabled must be false here — the module's
    # precondition requires cold_storage_transition_days < retention_days,
    # and the shared 90-day default would fail against a 30-day retention.
    versioning_enabled    = false
    retention_days        = 30
    cold_storage_enabled  = false
  }
}
