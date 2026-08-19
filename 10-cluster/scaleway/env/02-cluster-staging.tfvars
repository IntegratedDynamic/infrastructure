cluster_name = "scaleway-homelab"
node_count   = 2

# Cross-root state reads — see 00-foundation/scaleway/env/00-remote-state-backend.tfvars
# for the full bucket list.
backup_scaleway_state_bucket    = "id-terraform-state-03-storage-scaleway"
backup_scaleway_state_key       = "backup/scaleway/03-backup-dev-bucket/terraform.tfstate"
openbao_unseal_aws_state_bucket = "id-terraform-state-02-encryption-aws"
openbao_unseal_aws_state_key    = "openbao-unseal/aws/03-backup-dev-bucket/terraform.tfstate"
