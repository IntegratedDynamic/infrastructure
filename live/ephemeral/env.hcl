# Per-PR ephemeral clusters: one Terraform state per PR, all from the same unit.
#   name       -> workspace / state key: 10-cluster-scaleway-pr-<PR_NUMBER>
#   tfvars_env -> base values are the staging cluster's env/*.tfvars
# PR_NUMBER is set by .github/workflows/scaleway-ephemeral.yml. The "local"
# default keeps `run --all` parsing every unit without it (and lets you try an
# ephemeral cluster by hand without colliding with any PR's state).
locals {
  name       = "pr-${get_env("PR_NUMBER", "local")}"
  tfvars_env = "staging"
}
