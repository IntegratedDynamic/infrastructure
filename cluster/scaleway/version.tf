terraform {
  required_providers {
    scaleway = {
      source  = "scaleway/scaleway"
      version = "~> 2.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
  }
}

provider "scaleway" {}

# kubernetes/helm talk to the cluster directly via its Scaleway-issued
# kubeconfig attributes (no local-file dependency). On a from-scratch apply,
# run once with -var bootstrap_argocd=false: the cluster doesn't exist yet so
# these values are unknown, and gating ArgoCD off avoids exercising them.
provider "kubernetes" {
  host                   = scaleway_k8s_cluster.homelab.kubeconfig[0].host
  token                  = scaleway_k8s_cluster.homelab.kubeconfig[0].token
  cluster_ca_certificate = base64decode(scaleway_k8s_cluster.homelab.kubeconfig[0].cluster_ca_certificate)
}

provider "helm" {
  kubernetes {
    host                   = scaleway_k8s_cluster.homelab.kubeconfig[0].host
    token                  = scaleway_k8s_cluster.homelab.kubeconfig[0].token
    cluster_ca_certificate = base64decode(scaleway_k8s_cluster.homelab.kubeconfig[0].cluster_ca_certificate)
  }
}
