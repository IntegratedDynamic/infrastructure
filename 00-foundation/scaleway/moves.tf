# This root's buckets used to be declared directly here (scaleway_object_bucket.tfstate[...]
# + scaleway_object_bucket_server_side_encryption_configuration.tfstate[...]), with one shared
# identity for all of them. Moved into modules/scaleway-bucket-with-identity (one dedicated
# identity PER bucket by default) without touching any bucket's real data — these moved
# blocks just tell Terraform the buckets are the same objects, relocated in configuration.
# The old shared module.terraform_state_access_identity has no moved block: it's genuinely
# retired, replaced by the per-bucket identities below.

moved {
  from = scaleway_object_bucket.tfstate["scratch"]
  to   = module.state_buckets["scratch"].scaleway_object_bucket.this
}

moved {
  from = scaleway_object_bucket_server_side_encryption_configuration.tfstate["scratch"]
  to   = module.state_buckets["scratch"].scaleway_object_bucket_server_side_encryption_configuration.this
}

moved {
  from = scaleway_object_bucket.tfstate["foundation_scaleway"]
  to   = module.state_buckets["foundation_scaleway"].scaleway_object_bucket.this
}

moved {
  from = scaleway_object_bucket_server_side_encryption_configuration.tfstate["foundation_scaleway"]
  to   = module.state_buckets["foundation_scaleway"].scaleway_object_bucket_server_side_encryption_configuration.this
}

moved {
  from = scaleway_object_bucket.tfstate["iam_bootstrap_aws"]
  to   = module.state_buckets["iam_bootstrap_aws"].scaleway_object_bucket.this
}

moved {
  from = scaleway_object_bucket_server_side_encryption_configuration.tfstate["iam_bootstrap_aws"]
  to   = module.state_buckets["iam_bootstrap_aws"].scaleway_object_bucket_server_side_encryption_configuration.this
}

moved {
  from = scaleway_object_bucket.tfstate["iam_bootstrap_scaleway"]
  to   = module.state_buckets["iam_bootstrap_scaleway"].scaleway_object_bucket.this
}

moved {
  from = scaleway_object_bucket_server_side_encryption_configuration.tfstate["iam_bootstrap_scaleway"]
  to   = module.state_buckets["iam_bootstrap_scaleway"].scaleway_object_bucket_server_side_encryption_configuration.this
}

moved {
  from = scaleway_object_bucket.tfstate["iam_workload_scaleway"]
  to   = module.state_buckets["iam_workload_scaleway"].scaleway_object_bucket.this
}

moved {
  from = scaleway_object_bucket_server_side_encryption_configuration.tfstate["iam_workload_scaleway"]
  to   = module.state_buckets["iam_workload_scaleway"].scaleway_object_bucket_server_side_encryption_configuration.this
}

moved {
  from = scaleway_object_bucket.tfstate["encryption_aws"]
  to   = module.state_buckets["encryption_aws"].scaleway_object_bucket.this
}

moved {
  from = scaleway_object_bucket_server_side_encryption_configuration.tfstate["encryption_aws"]
  to   = module.state_buckets["encryption_aws"].scaleway_object_bucket_server_side_encryption_configuration.this
}

moved {
  from = scaleway_object_bucket.tfstate["storage_scaleway"]
  to   = module.state_buckets["storage_scaleway"].scaleway_object_bucket.this
}

moved {
  from = scaleway_object_bucket_server_side_encryption_configuration.tfstate["storage_scaleway"]
  to   = module.state_buckets["storage_scaleway"].scaleway_object_bucket_server_side_encryption_configuration.this
}

moved {
  from = scaleway_object_bucket.tfstate["vpn_wireguard_exit"]
  to   = module.state_buckets["vpn_wireguard_exit"].scaleway_object_bucket.this
}

moved {
  from = scaleway_object_bucket_server_side_encryption_configuration.tfstate["vpn_wireguard_exit"]
  to   = module.state_buckets["vpn_wireguard_exit"].scaleway_object_bucket_server_side_encryption_configuration.this
}

moved {
  from = scaleway_object_bucket.tfstate["vpn_wireguard_site_to_site"]
  to   = module.state_buckets["vpn_wireguard_site_to_site"].scaleway_object_bucket.this
}

moved {
  from = scaleway_object_bucket_server_side_encryption_configuration.tfstate["vpn_wireguard_site_to_site"]
  to   = module.state_buckets["vpn_wireguard_site_to_site"].scaleway_object_bucket_server_side_encryption_configuration.this
}

moved {
  from = scaleway_object_bucket.tfstate["secrets_openbao_bootstrap"]
  to   = module.state_buckets["secrets_openbao_bootstrap"].scaleway_object_bucket.this
}

moved {
  from = scaleway_object_bucket_server_side_encryption_configuration.tfstate["secrets_openbao_bootstrap"]
  to   = module.state_buckets["secrets_openbao_bootstrap"].scaleway_object_bucket_server_side_encryption_configuration.this
}

moved {
  from = scaleway_object_bucket.tfstate["secrets_openbao_managed"]
  to   = module.state_buckets["secrets_openbao_managed"].scaleway_object_bucket.this
}

moved {
  from = scaleway_object_bucket_server_side_encryption_configuration.tfstate["secrets_openbao_managed"]
  to   = module.state_buckets["secrets_openbao_managed"].scaleway_object_bucket_server_side_encryption_configuration.this
}

moved {
  from = scaleway_object_bucket.tfstate["monitoring_grafana_bootstrap"]
  to   = module.state_buckets["monitoring_grafana_bootstrap"].scaleway_object_bucket.this
}

moved {
  from = scaleway_object_bucket_server_side_encryption_configuration.tfstate["monitoring_grafana_bootstrap"]
  to   = module.state_buckets["monitoring_grafana_bootstrap"].scaleway_object_bucket_server_side_encryption_configuration.this
}

moved {
  from = scaleway_object_bucket.tfstate["monitoring_grafana_managed"]
  to   = module.state_buckets["monitoring_grafana_managed"].scaleway_object_bucket.this
}

moved {
  from = scaleway_object_bucket_server_side_encryption_configuration.tfstate["monitoring_grafana_managed"]
  to   = module.state_buckets["monitoring_grafana_managed"].scaleway_object_bucket_server_side_encryption_configuration.this
}

moved {
  from = scaleway_object_bucket.tfstate["cluster_scaleway"]
  to   = module.state_buckets["cluster_scaleway"].scaleway_object_bucket.this
}

moved {
  from = scaleway_object_bucket_server_side_encryption_configuration.tfstate["cluster_scaleway"]
  to   = module.state_buckets["cluster_scaleway"].scaleway_object_bucket_server_side_encryption_configuration.this
}

