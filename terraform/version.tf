terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
    infisical = {
      version = "~> 0.16"
      source = "infisical/infisical"
    }
  }
}

provider "kubernetes" {
  config_path = "~/.kube/config"
}

provider "helm" {
  kubernetes {
    config_path = "~/.kube/config"
  }
}

provider "infisical" {
  # host = "https://app.infisical.com" # Only required if using self hosted instance of Infisical, default is https://app.infisical.com
  auth = {
    # organization_slug = "<organization slug to scope the session to sub-org>"
    universal = {
      client_id     = var.infisical_client_id
      client_secret = var.infisical_client_secret
    }
  }
}
