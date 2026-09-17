# Rendered as a single YAML document, meant to be the FIRST entry in
# helm_release.argocd's own `values` list -- Helm deep-merges multiple
# values files in order given, so each root's own later entry (OIDC/Dex
# login, ArgoCD's public URL, RBAC policy, resource exclusions,
# metrics/serviceMonitor, ... -- genuinely environment-specific, not
# duplicated logic) only needs to add/override what it actually differs on.
output "values" {
  value = templatefile("${path.module}/values.yaml.tftpl", {
    memory_limit_mib = var.argocd_controller_memory_limit_mib
    gomemlimit_mib   = floor(var.argocd_controller_memory_limit_mib * 0.85)
  })
}
