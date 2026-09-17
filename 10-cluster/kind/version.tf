# No backend block, on purpose. This root's own kind cluster (created by a
# plain `kind create cluster` CI step
# before `tofu apply`, never by Terraform itself -- see infra#110) and its
# kubeconfig are both ephemeral within a single CI job, so there is nothing
# to persist across runs and no reason to want a remote S3-compatible
# backend at all (unlike every other root in this repo -- see
# 00-foundation/scaleway/README.md). Local state, single implicit
# "default" workspace.
terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
  }
}

provider "kubernetes" {
  config_path = "~/.kube/config"
}

provider "helm" {
  kubernetes = {
    config_path = "~/.kube/config"
  }
}
