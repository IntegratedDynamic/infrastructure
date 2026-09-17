output "application_name" {
  description = "The ArgoCD Application name (var.name, echoed back for convenience when building an app_names list for a module.wait-argocd-apps-healthy call)."
  value       = var.name
}

output "helm_release_revision" {
  description = "helm_release.this's own .metadata.revision -- for a caller building a module.wait-argocd-apps-healthy call's revision_trigger."
  value       = helm_release.this.metadata.revision
}
