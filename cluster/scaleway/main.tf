resource "scaleway_vpc_private_network" "cluster" {}

resource "scaleway_k8s_cluster" "homelab" {
  name    = "homelab"
  version = "1.35"

  auto_upgrade {
    enable                        = true
    maintenance_window_start_hour = 2
    maintenance_window_day        = "any"
  }
  cni                = "cilium"
  type               = "kapsule"
  private_network_id = scaleway_vpc_private_network.cluster.id

  # Alright for homelab, might not be true for production stuff
  delete_additional_resources = true

  tags = ["homelab", "terraform"]
}

resource "scaleway_k8s_pool" "default" {
  cluster_id  = scaleway_k8s_cluster.homelab.id
  name        = "default"
  node_type   = "DEV1-M"
  size        = var.node_count
  min_size    = 0
  max_size    = 3
  autoscaling = false
  autohealing = true

  lifecycle {
    create_before_destroy = true
  }
}

# Without waiting for at least one pool, the cluster status is `pool_required`
# and the DNS entry for the API server is not yet resolvable.
resource "null_resource" "kubeconfig" {
  depends_on = [scaleway_k8s_pool.default]
  triggers = {
    host                   = scaleway_k8s_cluster.homelab.kubeconfig[0].host
    token                  = scaleway_k8s_cluster.homelab.kubeconfig[0].token
    cluster_ca_certificate = scaleway_k8s_cluster.homelab.kubeconfig[0].cluster_ca_certificate
  }
}

resource "local_file" "kubeconfig" {
  depends_on      = [null_resource.kubeconfig]
  content         = scaleway_k8s_cluster.homelab.kubeconfig[0].config_file
  filename        = pathexpand("~/.kube/scaleway-homelab.yaml")
  file_permission = "0600"
}
