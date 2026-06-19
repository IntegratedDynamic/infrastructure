resource "scaleway_vpc_private_network" "cluster" {}

resource "scaleway_k8s_cluster" "this" {
  name    = var.cluster_name
  version = "1.35"

  auto_upgrade {
    enable                        = true
    maintenance_window_start_hour = 2
    maintenance_window_day        = "any"
  }
  cni                = "cilium"
  type               = "kapsule"
  private_network_id = scaleway_vpc_private_network.cluster.id

  delete_additional_resources = true

  tags = ["homelab", "terraform"]
}

resource "scaleway_k8s_pool" "default" {
  cluster_id  = scaleway_k8s_cluster.this.id
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

# ------------------------------------------------------------
# Optional ressource, mainly for local debugging capabilities.

locals {
  cluster_uuid = split("/", scaleway_k8s_cluster.this.id)[1]
}

resource "null_resource" "update_kubeconfig" {
  count = var.update_kubeconfig ? 1 : 0

  triggers = {
    cluster_id   = scaleway_k8s_cluster.this.id
    context_name = var.cluster_name
  }

  depends_on = [scaleway_k8s_pool.default]

  provisioner "local-exec" {
    command = <<-EOT
      scw k8s kubeconfig install ${local.cluster_uuid}
      # Override any pre-existing context with the target name, then rename.
      kubectl config delete-context "${var.cluster_name}" 2>/dev/null || true
      kubectl config rename-context "${scaleway_k8s_cluster.this.name}-${local.cluster_uuid}" "${var.cluster_name}"
    EOT
  }
}


data "infisical_secrets" "infisical" {
  env_slug     = "staging"
  workspace_id = "7ecb6ed4-058a-46cd-ac9f-7e792469cf0f" // project ID
  folder_path  = "/kubernetes"
}
