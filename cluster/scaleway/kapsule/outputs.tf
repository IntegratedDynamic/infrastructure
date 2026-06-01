output "cluster_id" {
  value = scaleway_k8s_cluster.homelab.id
}

output "kubeconfig_path" {
  value = pathexpand("~/.kube/scaleway-homelab.yaml")
}
