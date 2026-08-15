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
  loki = {
    bucket_name             = "monitoring-loki-dev-id"
    identity_app_prefix     = "monitoring-loki-k8s"
    identity_policy_prefix  = "monitoring-loki-objects"
    identity_purpose        = "grants Loki object read/write for log chunk storage"
    api_key_purpose         = "Loki workload credentials"
    api_key_consumer        = "Consumed via OpenBao (kv/apps/monitoring/loki-scaleway-s3-credentials) → ESO → Kubernetes Secret"

    # Same rolling-expiry shape as thanos above: log chunks age out on their
    # own schedule (Loki's own compactor/retention config, not this bucket),
    # so there's no value in backup/velero's versioning + GLACIER treatment —
    # it would just keep paying to store data Loki itself considers expired.
    # cold_storage_enabled must stay false: the module's precondition needs
    # cold_storage_transition_days < retention_days, and the shared 90-day
    # default would fail against this 1-day retention.
    #
    # 1 day, not 30 (2026-08-15): explicit call, not the module default —
    # matches Loki's own limits_config.retention_period
    # (services/platform/monitoring/loki-chart in the gitops repo, same
    # 24h) and Tempo's below, deliberately near-term-only.
    versioning_enabled    = false
    retention_days        = 1
    cold_storage_enabled  = false
  }
  tempo = {
    bucket_name             = "monitoring-tempo-dev-id"
    identity_app_prefix     = "monitoring-tempo-k8s"
    identity_policy_prefix  = "monitoring-tempo-objects"
    identity_purpose        = "grants Tempo object read/write for trace block storage"
    api_key_purpose         = "Tempo workload credentials"
    api_key_consumer        = "Consumed via OpenBao (kv/apps/monitoring/tempo-scaleway-s3-credentials) → ESO → Kubernetes Secret"

    # Same reasoning as loki above: trace blocks age out per Tempo's own
    # compactor/retention config, not this bucket's lifecycle rules.
    #
    # 1 day, not 30 (2026-08-15): matches Tempo's own retention (24h,
    # services/platform/monitoring/tempo-chart in the gitops repo).
    versioning_enabled    = false
    retention_days        = 1
    cold_storage_enabled  = false
  }
}
