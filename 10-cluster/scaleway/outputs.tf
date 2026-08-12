output "cluster_id" {
  value = scaleway_k8s_cluster.this.id
}

# Consumed by 05-secrets/openbao/managed's own `kubernetes` provider (via
# terraform_remote_state, same pattern that root already uses for
# dns_scaleway/backup_scaleway/wireguard/openbao_bootstrap) — it manages the
# ClusterSecretStore Kubernetes object alongside the vault_kubernetes_auth_backend_role
# it pairs with, so it needs cluster access too, without duplicating the
# scaleway_k8s_cluster resource itself.
output "cluster_host" {
  value = scaleway_k8s_cluster.this.kubeconfig[0].host
}

output "cluster_ca_certificate" {
  value = scaleway_k8s_cluster.this.kubeconfig[0].cluster_ca_certificate
}

output "cluster_token" {
  value     = scaleway_k8s_cluster.this.kubeconfig[0].token
  sensitive = true
}
