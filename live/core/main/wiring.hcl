# What is specific to this core, for the clusters that use it. Read by
# live/clusters/core.hcl; what a cluster runs is in live/types/.

inputs = {
  # var.domain -- see that variable's own comment in variables.tf. Every
  # cluster of this core inherits it; an ephemeral one
  # only adds its env_suffix -- "argocd-pr-123.staging.scalepack.fr", not a
  # separate domain.
  domain = "staging.scalepack.fr"

  # "staging" here (var.letsencrypt_staging / letsencrypt-staging ClusterIssuer)
  # is Let's Encrypt's own ACME environment (vs. letsencrypt-prod's tight rate
  # limits) -- an UNRELATED axis from this homelab also being named
  # "staging" (this homelab's own environment tier, *.staging.scalepack.fr,
  # vs. a future *.prod.scalepack.fr cluster not yet created). Don't conflate
  # the two: this cluster's own tier can run on EITHER ACME environment.
  #
  # This homelab now runs on Let's Encrypt PROD certs (switched 2026-11-17).
  # It used to sit on STAGING for two reasons, neither holds anymore:
  #  1. the cluster was rebuilt (up/down) often enough that LE's prod rate limit
  #     (5 duplicate certs/week) was a real risk -- it is no longer torn down
  #     routinely;
  #  2. gateway/cert-restore restores the wildcard TLS Secret from the latest
  #     Velero backup, and every backup then was staging-issued, so the platform
  #     had to trust the staging root. cert-manager re-issues when the Secret's
  #     issuer differs from the active ClusterIssuer, which is what the flip
  #     relies on.
  # Reason to flip back to true: a burst of same-week rebuilds hitting the rate
  # limit again (and then flip it back once the window passes). Public webhooks
  # (GitHub -> hooks.staging.scalepack.fr) need a publicly trusted cert, which is
  # why this moved.
  letsencrypt_staging = false
}
