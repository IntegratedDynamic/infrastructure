# infra#110 + infra#113: this tier's whole platform-apps DAG lives as DATA
# in env/10-cluster-kind-github-pr.tfvars (var.domains, see
# modules/platform-apps-dag/variables.tf's own description) -- this file now
# only holds ArgoCD's own bootstrap (helm_release.argocd, no OIDC/Dex login
# here, unlike 10-cluster/scaleway's shared Dex -- every access here is
# already the CI job's own kubeconfig admin) and the handful of Secret
# dependencies (main.tf) that can't be expressed as tfvars data, merged onto
# var.domains right before the single module.platform_apps call. See that
# module's main.tf for why the per-domain module deliberately does NOT also
# own its wait gate (soft vs. hard cross-domain dependencies would otherwise
# collapse into always-hard), and 10-cluster/scaleway/platform-apps/README.md
# for the platform-wide DAG this wiring encodes.
#
# See env/10-cluster-kind-github-pr.tfvars for what's trimmed relative to
# the Scaleway DAG (wireguard-apps/crossplane-apps/monitoring-apps, no
# `bootstrap` Application) and why.

module "argocd_base_values" {
  source = "../modules/argocd-base-values"
}

resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "9.4.17"

  timeout = 240

  values = [
    module.argocd_base_values.values,
    <<-EOF
    configs:
      rbac:
        # No OIDC/Dex login wired up for this ephemeral, single-use tier
        # (unlike 10-cluster/scaleway's shared Dex) -- every access here is
        # already the CI job's own kubeconfig admin, so there's no separate
        # audience to restrict.
        policy.default: role:admin
    EOF
  ]
}

# Extra dependencies var.domains can't express itself -- a literal string in
# tfvars couldn't reference a real Terraform resource. Both Secret groups
# below (main.tf) use creationPolicy: Merge on the ESO side, so they must
# already exist before the consuming domain's first sync (see main.tf's own
# header comment) -- expressed here as each domain's depends_on_ids, folded
# into module.platform_apps' single merge below.
locals {
  domain_extra_depends_on_ids = {
    secrets-apps = [
      kubernetes_secret.scaleway_s3_credentials.id,
      kubernetes_secret.openbao_unseal_aws.id,
      kubernetes_secret.scaleway_dns_credentials.id,
      kubernetes_secret.external_dns_scaleway_credentials.id,
    ]
    backups-apps = [
      kubernetes_secret.velero_scaleway_credentials.id,
    ]
  }

  domains = {
    for key, d in var.domains : key => merge(d, {
      depends_on_ids = concat(d.depends_on_ids, lookup(local.domain_extra_depends_on_ids, key, []))
    })
  }
}

module "platform_apps" {
  source = "../modules/platform-apps-dag"

  domains = local.domains

  # No git-existence-probe machinery here (unlike 10-cluster/scaleway) --
  # this tier only ever runs from a real PR's own checkout, so the ref it's
  # told to use always exists.
  infra_revision  = var.infra_revision
  gitops_revision = var.gitops_revision

  depends_on = [helm_release.argocd]
}
