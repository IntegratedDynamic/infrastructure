output "service_account_name" {
  description = "Name of the ServiceAccount every module.wait-argocd-apps-healthy / module.argocd-platform-domain instance in this root should run as."
  value       = kubernetes_service_account.wait_platform_apps.metadata[0].name
}

output "role_binding_id" {
  description = "id of the RoleBinding -- exposed only so a caller can add it as an explicit depends_on target alongside the ServiceAccount, matching this repo's existing convention of depending on the RoleBinding (not just the ServiceAccount) before any Job using it is created."
  value       = kubernetes_role_binding.wait_platform_apps.id
}
