terraform {
  # Migrated to the dedicated Scaleway state bucket (00-foundation/scaleway,
  # state_buckets["cluster_scaleway"]).
  backend "s3" {
    bucket                      = "id-terraform-state-10-cluster-scaleway"
    region                      = "fr-par"
    workspace_key_prefix        = "cluster/scaleway"
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
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    # infisical = {
    #   source  = "infisical/infisical"
    #   version = "~> 0.16"
    # }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.0"
    }
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
