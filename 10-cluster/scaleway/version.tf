terraform {
  # Remote state in the org-wide bucket (state-backend/). Creds: see mise.toml.
  backend "s3" {
    bucket               = "id-terraform-state20260612164136440800000001"
    region               = "eu-west-3"
    workspace_key_prefix = "cluster/scaleway"
    key                  = "terraform.tfstate"
    encrypt              = true
    use_lockfile         = true
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
    # infisical = {
    #   source  = "infisical/infisical"
    #   version = "~> 0.16"
    # }
  }
}

provider "scaleway" {}

# provider "infisical" {
  
#   auth = { 
#     ## Uncomment `universal` and comment `oidc` when running terraform locally.
#     ## By default, even with `INFISICAL_UNIVERSAL_AUTH_CLIENT_XXXX` environment variable, due to `auth.oidc` being present, infisical provider expect OIDC configuration, and nothing else.
#     # universal = {} 
#     oidc = {} 
#   }
# }

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
