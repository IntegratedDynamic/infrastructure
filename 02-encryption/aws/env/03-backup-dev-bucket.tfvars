# Filename kept identical to the workspace this root's resources had inside
# 03-backup/scaleway (now 03-storage/scaleway) — DO NOT rename this file.
# local.unseal_name in main.tf derives the live KMS alias + IAM user name from
# terraform.workspace, which comes from this filename. Renaming it would make
# Terraform want to rename/recreate the KMS alias and IAM user in place.
aws_region = "eu-west-3"
