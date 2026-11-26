# Terragrunt root config — included by every unit under live/<env>/<root path>/.
#
# WHAT THIS REPLACES (see CLAUDE.md "Backend keys are decoupled from paths"):
#  - the 5-line `backend "s3"` block that used to be copy-pasted in every root's
#    version.tf (a backend block cannot read variables, hence the copies);
#  - `tofu workspace select -or-create <name>` + `-var-file=env/<name>.tfvars`,
#    repeated in .github/actions/terraform and in the mise tasks.
#
# LAYOUT: live/<env>/<root path>/terragrunt.hcl, e.g.
#   live/dev/03-storage/scaleway/terragrunt.hcl  ->  root 03-storage/scaleway, env "dev"
# The Terraform code stays where it is (nothing moved: the Crossplane
# Workspaces pin this repo's root paths via `?ref=`); `live/` only adds the
# per-environment wiring on top of it.
#
# SAME STATE OBJECT, NO MIGRATION: the s3 backend stores a non-default
# workspace at <workspace_key_prefix>/<workspace>/<key>. Terragrunt runs the
# *default* workspace instead, with `key` set to that exact full path, so it
# reads/writes the very same object (and the same .tflock). Cross-root
# readers (11-secrets/openbao/managed's terraform_remote_state, ...) keep
# working untouched. The legacy workspace name still exists as a plain
# string (local.workspace below) and is handed to the root as
# var.workspace_name, for the roots whose resource names embed it (what
# `terraform.workspace` used to be — it is "default" under Terragrunt).

locals {
  # "dev/03-storage/scaleway" -> env dir "dev", root path "03-storage/scaleway"
  parts     = split("/", path_relative_to_include())
  env_dir   = local.parts[0]
  root_path = join("/", slice(local.parts, 1, length(local.parts)))
  slug      = replace(local.root_path, "/", "-") # "03-storage-scaleway"

  # live/<env dir>/env.hcl is optional. `locals { name = "pr-123" }` renames the
  # environment in the workspace/state key (the ephemeral clusters: one state
  # per PR, same unit); `tfvars_env = "staging"` reads another environment's
  # env/*.tfvars as the base values.
  env_cfg = read_terragrunt_config("${get_parent_terragrunt_dir()}/${local.env_dir}/env.hcl", { locals = {} })
  env     = lookup(local.env_cfg.locals, "name", local.env_dir)

  # The workspace name every root used until now: <path flattened>-<env>.
  workspace = "${local.slug}-${local.env}"
  tfvars    = "${local.slug}-${lookup(local.env_cfg.locals, "tfvars_env", local.env)}.tfvars"

  # State buckets are named id-terraform-state-<path flattened> (provisioned by
  # 00-foundation/scaleway's var.state_buckets, not by Terragrunt). A bucket
  # cannot be renamed, so a root renamed after its bucket existed keeps the old
  # name here.
  bucket_overrides = {
    "11-secrets/openbao/bootstrap" = "id-terraform-state-05-secrets-openbao-bootstrap"
  }
  bucket = lookup(local.bucket_overrides, local.root_path, "id-terraform-state-${local.slug}")

  # The s3 backend only ever reads the literal AWS_ACCESS_KEY_ID /
  # AWS_SECRET_ACCESS_KEY env vars, which for a Scaleway-hosted state hold the
  # Scaleway key pair (CLAUDE.md "Setup"). A root with a REAL `provider "aws"`
  # reads those same two names for its own AWS calls — collision (the "known
  # follow-up" in CLAUDE.md / 00-foundation/scaleway/README.md). For those
  # roots the state key pair is written into the generated backend.tf instead,
  # from SCALEWAY_STATE_ACCESS_KEY / SCALEWAY_STATE_SECRET_KEY (the names CI
  # already uses). It lands in .terragrunt-cache/ (gitignored) and in that
  # cache's .terraform/ — the same exposure as the gitignored -backend-config
  # file this replaces. AWS_* stays free for the AWS provider (aws sso login).
  explicit_state_credentials_roots = ["01-iam/bootstrap/aws", "02-encryption/aws"]
  state_credentials = contains(local.explicit_state_credentials_roots, local.root_path) ? {
    access_key = get_env("SCALEWAY_STATE_ACCESS_KEY")
    secret_key = get_env("SCALEWAY_STATE_SECRET_KEY")
  } : {}
}

terraform {
  # Double slash: Terragrunt copies everything under `//` into its cache dir,
  # and the roots reference ../../modules/*, platform-apps/ and files/ by
  # relative path — those must land in the copy too.
  source = "${get_repo_root()}//${local.root_path}"

  # The committed lock file stays the one in the root's own directory (it is
  # what `mise run lock` and the Verify OpenTofu Lock Files workflow maintain,
  # for darwin_arm64 + linux_amd64). Terragrunt would otherwise copy it back
  # next to each live/ unit, a second copy that takes precedence over the
  # root's on the next run.
  copy_terraform_lock_file = false

  # Reuse each root's existing env/<workspace>.tfvars verbatim: one source of
  # truth while both the classic workflow and Terragrunt exist.
  extra_arguments "env_tfvars" {
    commands           = get_terraform_commands_that_need_vars()
    required_var_files = ["${get_repo_root()}/${local.root_path}/env/${local.tfvars}"]
  }
}

remote_state {
  backend = "s3"

  # The buckets already exist (00-foundation/scaleway creates them, with their
  # own scoped identity, versioning, lifecycle). Terragrunt's bootstrap would
  # try to create/alter them with AWS-specific calls: don't let it.
  disable_init = true

  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }

  config = merge({
    bucket  = local.bucket
    key     = "${local.root_path}/${local.workspace}/terraform.tfstate"
    region  = "fr-par"
    encrypt = true

    # Scaleway Object Storage as an S3-compatible store — same settings the
    # per-root backend blocks carried (see 00-foundation/scaleway/README.md).
    use_lockfile                = true
    use_path_style              = true
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
    endpoints = {
      s3 = "https://s3.fr-par.scw.cloud"
    }
  }, local.state_credentials)
}
