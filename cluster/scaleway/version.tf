terraform {
  # Remote state in the org-wide bucket (state-backend/). Creds: see mise.toml.
  backend "s3" {
    bucket = "id-terraform-state"
    key    = "cluster/scaleway/terraform.tfstate"
    region = "fr-par"

    # Root-specific prefix so this root's workspaces don't mix with others'.
    workspace_key_prefix = "cluster/scaleway"

    endpoints = { s3 = "https://s3.fr-par.scw.cloud" }

    # Disable the backend's AWS-only preflight checks (IMDS, STS account-id,
    # region allowlist): Scaleway speaks the S3 API but isn't AWS itself.
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
  }

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
      version = "~> 3.0"
    }
    infisical = {
      source  = "infisical/infisical"
      version = "~> 0.16"
    }
  }
}

provider "scaleway" {}

provider "infisical" {
  auth = {
    universal = {
      client_id     = var.infisical_client_id
      client_secret = var.infisical_client_secret
    }
  }
}

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
  kubernetes = {
    host                   = scaleway_k8s_cluster.homelab.kubeconfig[0].host
    token                  = scaleway_k8s_cluster.homelab.kubeconfig[0].token
    cluster_ca_certificate = base64decode(scaleway_k8s_cluster.homelab.kubeconfig[0].cluster_ca_certificate)
  }
}
