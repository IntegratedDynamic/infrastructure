# Per-PR ephemeral clusters: one state per PR, all from the same unit.
#   name       -> state key: 10-cluster/scaleway/pr-<PR_NUMBER>/terraform.tfstate
#   tfvars_env -> base values are the staging cluster's env/*.tfvars
# PR_NUMBER is set by .github/workflows/scaleway-ephemeral.yml. The "local"
# default keeps `run --all` parsing every unit without it.
locals {
  core       = "main"
  name       = "pr-${get_env("PR_NUMBER", "local")}"
  tfvars_env = "staging"
}
