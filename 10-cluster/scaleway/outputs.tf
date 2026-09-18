output "cluster_id" {
  value = scaleway_k8s_cluster.this.id
}

# infra#113 SSO-fix follow-up: empty on the stable workspace (see
# argocd.tf's local.dex_static_password) -- only meaningful for an
# ephemeral workspace, where it's the Dex local-password-DB login
# (https://auth<hostSuffix>.scalepack.fr, username "ephemeral") that
# stands in for the real GitHub connector. sensitive = true: this is a
# real (if throwaway, internet-facing) credential, not just a value that
# happens to be secret-shaped.
output "dex_static_password" {
  value     = local.dex_static_password
  sensitive = true
}
