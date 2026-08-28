cluster_name = "scaleway-homelab"
node_count   = 2

# Cross-root state reads — see 00-foundation/scaleway/env/00-foundation-scaleway-dev.tfvars
# for the full bucket list. Keys updated 2026-08-24 (workspace-naming
# refacto) to point at each target root's new prefix/workspace.
backup_scaleway_state_bucket    = "id-terraform-state-03-storage-scaleway"
backup_scaleway_state_key       = "03-storage/scaleway/03-storage-scaleway-dev/terraform.tfstate"
openbao_unseal_aws_state_bucket = "id-terraform-state-02-encryption-aws"
openbao_unseal_aws_state_key    = "02-encryption/aws/02-encryption-aws-dev/terraform.tfstate"
dns_scaleway_state_bucket       = "id-terraform-state-01-iam-workload-scaleway"
dns_scaleway_state_key          = "01-iam/workload/scaleway/01-iam-workload-scaleway-dev/terraform.tfstate"
