variable "k8s_version" {
  type    = string
  default = "1.32.3"
}

variable "node_count" {
  type    = number
  default = 1
}

variable "bootstrap_argocd" {
  description = "Install ArgoCD + the bootstrap Application on the cluster. Set false to provision the cluster alone (e.g. the very first apply, before the kubeconfig exists)."
  type        = bool
  default     = true
}

variable "gitops_revision" {
  type    = string
  default = "main"
}
