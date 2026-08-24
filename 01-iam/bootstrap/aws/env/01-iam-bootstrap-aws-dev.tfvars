region = "eu-west-3"

# 00-foundation/aws never migrates off AWS — see main.tf's data source
# comment — so these stay constant. Explicit here (not just the variables.tf
# default) so the cross-root target is visible as config, not hidden in code.
remote_state_aws_bucket = "id-terraform-state20260612164136440800000001"
remote_state_aws_region = "eu-west-3"
remote_state_aws_key    = "state-backend/00-remote-state-backend/terraform.tfstate"
