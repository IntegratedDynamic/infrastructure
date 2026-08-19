project_id                         = "6283c05b-a4c7-4f83-a75f-83adad236d54"
region                             = "fr-par"
noncurrent_version_expiration_days = 10

# Rehearsal bucket for the now-deleted 99-scratch/migration-test root — left
# in place intentionally (prevent_destroy included), cleanup is a manual
# admin action on their own timeline. Do not remove or touch it.
state_buckets = {
  scratch = {
    bucket_name = "id-terraform-state-99-scratch-migration-test"
  }

  # This root's own state (bootstrap: created while backend still points at
  # the AWS bucket, then repointed here — same pattern 00-foundation/aws used
  # for itself).
  foundation_scaleway = {
    bucket_name = "id-terraform-state-00-foundation-scaleway"
  }

  iam_bootstrap_aws = {
    bucket_name = "id-terraform-state-01-iam-bootstrap-aws"
  }
  iam_bootstrap_scaleway = {
    bucket_name = "id-terraform-state-01-iam-bootstrap-scaleway"
  }
  iam_workload_scaleway = {
    bucket_name = "id-terraform-state-01-iam-workload-scaleway"
  }
  encryption_aws = {
    bucket_name = "id-terraform-state-02-encryption-aws"
  }
  storage_scaleway = {
    bucket_name = "id-terraform-state-03-storage-scaleway"
  }
  vpn_wireguard_exit = {
    bucket_name = "id-terraform-state-04-vpn-wireguard-exit"
  }
  vpn_wireguard_site_to_site = {
    bucket_name = "id-terraform-state-04-vpn-wireguard-site-to-site"
  }
  secrets_openbao_bootstrap = {
    bucket_name = "id-terraform-state-05-secrets-openbao-bootstrap"
  }
  secrets_openbao_managed = {
    bucket_name = "id-terraform-state-05-secrets-openbao-managed"
  }
  monitoring_grafana_bootstrap = {
    bucket_name = "id-terraform-state-06-monitoring-grafana-bootstrap"
  }
  monitoring_grafana_managed = {
    bucket_name = "id-terraform-state-06-monitoring-grafana-managed"
  }
  cluster_scaleway = {
    bucket_name = "id-terraform-state-10-cluster-scaleway"
  }
}
