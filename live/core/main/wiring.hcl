# What is specific to this core, for the clusters that use it. Read by
# live/clusters/core.hcl. Only what differs between cores AND is the same for
# every cluster of a core belongs here; what depends on the kind of cluster is in
# live/types/.

inputs = {
  # var.domain -- see that variable's own comment in variables.tf. Every
  # cluster of this core inherits it; an ephemeral one
  # only adds its env_suffix -- "argocd-pr-123.staging.scalepack.fr", not a
  # separate domain.
  domain = "staging.scalepack.fr"
}
