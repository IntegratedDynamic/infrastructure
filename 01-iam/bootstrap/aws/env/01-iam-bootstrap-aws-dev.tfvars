region = "eu-west-3"

# 00-foundation/aws's state, read by main.tf. Explicit here (not just the
# variables.tf default) so the cross-root target is visible as config.
remote_state_aws_bucket = "id-terraform-state-00-foundation-aws"
remote_state_aws_key    = "00-foundation/aws/00-foundation-aws-dev/terraform.tfstate"

# `aws sso login --profile infrastructure` first.
aws_profile = "infrastructure"
