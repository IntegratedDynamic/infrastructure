# A full copy of the homelab cluster for one PR (label `ephemeral-cluster`),
# in its own state (10-cluster/scaleway/pr-<PR_NUMBER>/), every platform
# hostname suffixed -pr-<N>. Same recipe (live/types/main.hcl) and core wiring as
# the staging cluster; the overrides below go on the command line, which beats
# `inputs`.
#
# Opt-in for `run --all` like the staging cluster (it is a paid cluster).

include "root" {
  path           = find_in_parent_folders("root.hcl")
  expose         = true
  merge_strategy = "deep"
}

include "core" {
  path = find_in_parent_folders("core.hcl")
}

include "type" {
  path = "${get_repo_root()}/live/types/main.hcl"
}

locals {
  instance = include.root.locals.instance # "pr-<PR_NUMBER>"
}

# One cache per PR: the state key (backend) depends on PR_NUMBER, and OpenTofu
# refuses to re-init a cache whose backend config changed ("Backend configuration
# changed"). Sharing one cache dir would make switching PR_NUMBER locally fail.
# Still under .terragrunt-cache/, so gitignored.
download_dir = "${get_terragrunt_dir()}/.terragrunt-cache/${local.instance}"

terraform {
  extra_arguments "ephemeral_overrides" {
    commands = get_terraform_commands_that_need_vars()
    arguments = flatten([
      ["-var", "cluster_name=${local.instance}"],
      ["-var", "env_suffix=${local.instance}"],
      # Each ephemeral cluster orders its own *.staging.scalepack.fr wildcard;
      # prod Let's Encrypt's rate limit (5 duplicate certs/week) would be burnt
      # by a few PR clusters.
      ["-var", "letsencrypt_staging=true"],
      # crossplane-apps' tofu-apply-in-a-Workspace loop takes far longer to
      # first-converge than the rest; an ephemeral run just wants the core
      # platform up (confirmed live 2026-09-16, ephemeral cluster pr-109).
      ["-var", "wait_all_domains_healthy=false"],
      # The PR's own head ref: unset locally, where infra_revision then
      # auto-detects the checked-out branch (variables.tf).
      get_env("HEAD_REF", "") != "" ? ["-var", "infra_revision=${get_env("HEAD_REF")}"] : [],
    ])
  }
}

feature "cluster" {
  default = false
}

exclude {
  if      = !feature.cluster.value
  actions = ["all_except_output"]
}
