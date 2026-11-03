# api_key is sensitive, supplied via a gitignored *.auto.tfvars instead (see
# README's "Bootstrap credentials" section); `tailnet` defaults to the
# tailnet owning that key (see variables.tf). Everything below is
# non-secret config. The filename still sets the workspace name per the
# repo-wide convention -- see root CLAUDE.md's "Backend keys are decoupled
# from paths".

federated_identities = {
  # GitHub Actions -> tailnet for live CI debugging
  # (.github/actions/debug-tailscale, infra#110). Subject is repo-wide, any
  # workflow/branch/event, mirroring 00-foundation/aws's
  # terraform-state-access trust scope. Key is pinned: outputs.tf's legacy
  # ci_debug_* outputs (read by 11-secrets/openbao/managed) look it up.
  ci_debug = {
    description = "GitHub Actions OIDC for infra110 CI debug"
    issuer      = "https://token.actions.githubusercontent.com"
    subject     = "repo:IntegratedDynamic/infrastructure:*"
    audience    = "tailscale-ci-debug"
    tags        = ["tag:ci-debug"]
  }
}
