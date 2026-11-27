# Shared Terragrunt config, included by every unit under live/<env>/<root path>/.
# Everything is derived from that path; see live/README.md.

locals {
  # "dev/03-storage/scaleway" -> env dir "dev", root path "03-storage/scaleway"
  parts     = split("/", path_relative_to_include())
  env_dir   = local.parts[0]
  root_path = join("/", slice(local.parts, 1, length(local.parts)))
  root_dir  = "${get_repo_root()}/${local.root_path}"
  slug      = replace(local.root_path, "/", "-") # "03-storage-scaleway"

  # live/<env dir>/env.hcl is optional: `name` renames the environment in the
  # state key (one state per PR), `tfvars_env` borrows another environment's
  # tfvars. Only live/ephemeral has one.
  env_cfg = read_terragrunt_config("${get_parent_terragrunt_dir()}/${local.env_dir}/env.hcl", { locals = {} })
  env     = lookup(local.env_cfg.locals, "name", local.env_dir)

  workspace = "${local.slug}-${local.env}"
  tfvars    = "${local.slug}-${lookup(local.env_cfg.locals, "tfvars_env", local.env)}.tfvars"
}

terraform {
  # `//`: the whole repo is copied into the cache, because roots reference
  # ../../modules, platform-apps/ and files/ by relative path.
  source = "${get_repo_root()}//${local.root_path}"

  # Never copy local secrets or state into the cache.
  exclude_from_copy = [
    "**/generated", "**/generated/**", # WireGuard private keys
    "**/*.conf",
    "**/*.auto.tfvars",
    "**/*.tfstate*",
  ]

  # The lock file stays in the root's own directory (`mise run lock`).
  copy_terraform_lock_file = false

  # The root's own gitignored overrides, read in place since they are not
  # copied. Declared first: the env tfvars below wins, as it did before.
  extra_arguments "local_overrides" {
    commands = get_terraform_commands_that_need_vars()
    arguments = [
      for f in fileset(local.root_dir, "*.auto.tfvars") : "-var-file=${local.root_dir}/${f}"
    ]
  }

  extra_arguments "env_tfvars" {
    commands           = get_terraform_commands_that_need_vars()
    required_var_files = ["${local.root_dir}/env/${local.tfvars}"]
  }
}

# For the roots that build resource names from it (`terraform.workspace` is
# always "default" here). Roots without that variable ignore it.
inputs = {
  workspace_name = local.workspace
}

# One bucket per root, created by 00-foundation/scaleway. The state credentials
# are the usual AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY (CLAUDE.md "Setup").
remote_state {
  backend = "s3"

  # Terragrunt must not create or alter the buckets.
  disable_init = true

  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }

  config = {
    bucket  = "id-terraform-state-${local.slug}"
    key     = "${local.root_path}/${local.workspace}/terraform.tfstate"
    region  = "fr-par"
    encrypt = true

    # Scaleway Object Storage as an S3-compatible store, see
    # 00-foundation/scaleway/README.md.
    use_lockfile                = true
    use_path_style              = true
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
    endpoints = {
      s3 = "https://s3.fr-par.scw.cloud"
    }
  }
}
