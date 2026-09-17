# No non-secret variables needed currently -- `tailnet` defaults to the
# tailnet owning the bootstrap API key (see variables.tf), and the only
# other variable (api_key) is sensitive, supplied via a gitignored
# *.auto.tfvars instead (see README's "Bootstrap credentials" section).
# This file still exists so the workspace name (derived from the filename)
# matches the repo-wide convention -- see root CLAUDE.md's "Backend keys
# are decoupled from paths".
