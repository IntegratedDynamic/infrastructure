terraform {
  # Migrated to the dedicated Scaleway state bucket (00-foundation/scaleway,
  # state_buckets["cluster_scaleway"]).
  #
  # Prefix + workspace name now mirror this root's own path (2026-08-24
  # workspace-naming refacto) — used to be "cluster/scaleway" (missing the
  # numeric prefix every other root's now has) / "02-cluster-staging" (wrong
  # domain number, and "staging" was flatly misleading — this is a personal
  # dev homelab, never staging or prod). No terraform.workspace naming
  # coupling in this root (the cluster's own name comes from elsewhere, not
  # the workspace), so this is a plain state relocation, zero resource
  # impact. Old state object left in place under the old prefix/workspace,
  # orphaned on purpose (never deleted).
  backend "s3" {
    bucket                      = "id-terraform-state-10-cluster-scaleway"
    region                      = "fr-par"
    workspace_key_prefix        = "10-cluster/scaleway"
    key                         = "terraform.tfstate"
    encrypt                     = true
    use_lockfile                = true
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
    use_path_style              = true
    endpoints = {
      s3 = "https://s3.fr-par.scw.cloud"
    }
  }

  required_providers {
    scaleway = {
      source  = "scaleway/scaleway"
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
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.0"
    }
  }
}

provider "scaleway" {}

provider "kubernetes" {
  host                   = scaleway_k8s_cluster.this.kubeconfig[0].host
  token                  = scaleway_k8s_cluster.this.kubeconfig[0].token
  cluster_ca_certificate = base64decode(scaleway_k8s_cluster.this.kubeconfig[0].cluster_ca_certificate)
}

provider "helm" {
  kubernetes = {
    host                   = scaleway_k8s_cluster.this.kubeconfig[0].host
    token                  = scaleway_k8s_cluster.this.kubeconfig[0].token
    cluster_ca_certificate = base64decode(scaleway_k8s_cluster.this.kubeconfig[0].cluster_ca_certificate)
  }
}
