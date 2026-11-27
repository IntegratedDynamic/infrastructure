# Shared Terragrunt config, included by every unit:
#   live/core/<core>/<root path>/       the platform a cluster needs
#   live/clusters/<cluster>/<root path>/
# Everything is derived from that path; see live/README.md.

locals {
  # Example values for live/core/main/03-storage/scaleway.
  parts     = split("/", path_relative_to_include())                # ["core", "main", "03-storage", "scaleway"]
  group     = local.parts[0]                                        # "core" (or "clusters")
  folder    = local.parts[1]                                        # "main" (or "staging", "ephemeral", "kind")
  root_path = join("/", slice(local.parts, 2, length(local.parts))) # "03-storage/scaleway"
  root_dir  = "${get_repo_root()}/${local.root_path}"               # "<repo>/03-storage/scaleway"
  slug      = replace(local.root_path, "/", "-")                    # "03-storage-scaleway"

  # A cluster's cluster.hcl, empty for a core. `name` renames the instance (one
  # state per PR for "ephemeral"), `tfvars_env` borrows another one's tfvars.
  cluster = read_terragrunt_config( # { locals = {} }
    "${get_parent_terragrunt_dir()}/${local.group}/${local.folder}/cluster.hcl", { locals = {} }
  )
  instance = lookup(local.cluster.locals, "name", local.folder)                                   # "main" ("pr-123")
  tfvars   = "${local.slug}-${lookup(local.cluster.locals, "tfvars_env", local.instance)}.tfvars" # "03-storage-scaleway-main.tfvars"
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
  workspace_name = "${local.slug}-${local.instance}" # "03-storage-scaleway-main"
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
    key     = "${local.root_path}/${local.instance}/terraform.tfstate" # "03-storage/scaleway/main/terraform.tfstate"
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
