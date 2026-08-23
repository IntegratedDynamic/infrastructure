output "bucket_name" {
  description = "Provisioned backup bucket name."
  value       = module.buckets["backup"].bucket_name
}

output "bucket_region" {
  description = "Region the backup bucket was created in."
  value       = module.buckets["backup"].bucket_region
}

output "bucket_endpoint" {
  description = "S3-compatible endpoint URL for the backup bucket."
  value       = module.buckets["backup"].bucket_endpoint
}

output "workload_access_key" {
  description = "Public access key for the scoped Kubernetes backup workload identity. The secret key is in Infisical only."
  value       = module.buckets["backup"].access_key
}

output "workload_secret_key" {
  sensitive   = true
  description = "Public access key for the scoped Kubernetes backup workload identity. The secret key is in Infisical only."
  value       = module.buckets["backup"].secret_key
}

# ── Velero (separate bucket + identity) ──────────────────────────────────────

output "velero_bucket_name" {
  description = "Provisioned Velero backup bucket name."
  value       = module.buckets["velero"].bucket_name
}

output "velero_workload_access_key" {
  description = "Public access key for the scoped Velero Kubernetes workload identity."
  value       = module.buckets["velero"].access_key
}

output "velero_workload_secret_key" {
  sensitive   = true
  description = "Secret access key for the scoped Velero Kubernetes workload identity."
  value       = module.buckets["velero"].secret_key
}

# ── Thanos (separate bucket + identity) ──────────────────────────────────────

output "thanos_bucket_name" {
  description = "Provisioned Thanos object-storage bucket name."
  value       = module.buckets["thanos"].bucket_name
}

output "thanos_workload_access_key" {
  description = "Public access key for the scoped Thanos Kubernetes workload identity."
  value       = module.buckets["thanos"].access_key
}

output "thanos_workload_secret_key" {
  sensitive   = true
  description = "Secret access key for the scoped Thanos Kubernetes workload identity."
  value       = module.buckets["thanos"].secret_key
}

# ── Loki (separate bucket + identity) ─────────────────────────────────────────

output "loki_bucket_name" {
  description = "Provisioned Loki object-storage bucket name."
  value       = module.buckets["loki"].bucket_name
}

output "loki_workload_access_key" {
  description = "Public access key for the scoped Loki Kubernetes workload identity."
  value       = module.buckets["loki"].access_key
}

output "loki_workload_secret_key" {
  sensitive   = true
  description = "Secret access key for the scoped Loki Kubernetes workload identity."
  value       = module.buckets["loki"].secret_key
}

# ── Tempo (separate bucket + identity) ────────────────────────────────────────

output "tempo_bucket_name" {
  description = "Provisioned Tempo object-storage bucket name."
  value       = module.buckets["tempo"].bucket_name
}

output "tempo_workload_access_key" {
  description = "Public access key for the scoped Tempo Kubernetes workload identity."
  value       = module.buckets["tempo"].access_key
}

output "tempo_workload_secret_key" {
  sensitive   = true
  description = "Secret access key for the scoped Tempo Kubernetes workload identity."
  value       = module.buckets["tempo"].secret_key
}

# ── Argo Workflows log archive (separate bucket + identity) ──────────────────

output "argo_workflows_logs_bucket_name" {
  description = "Provisioned Argo Workflows log-archive bucket name."
  value       = module.buckets["argo_workflows_logs"].bucket_name
}

output "argo_workflows_logs_workload_access_key" {
  description = "Public access key for the scoped Argo Workflows log-archive Kubernetes workload identity."
  value       = module.buckets["argo_workflows_logs"].access_key
}

output "argo_workflows_logs_workload_secret_key" {
  sensitive   = true
  description = "Secret access key for the scoped Argo Workflows log-archive Kubernetes workload identity."
  value       = module.buckets["argo_workflows_logs"].secret_key
}
