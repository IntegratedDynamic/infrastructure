# Required only when bootstrap_argocd = true (to read the ArgoCD admin hash).
# Default empty so a cluster-only provision (bootstrap_argocd = false) needs no creds.
variable "infisical_client_id" {
  type    = string
  default = ""
}

variable "infisical_client_secret" {
  type      = string
  default   = ""
  sensitive = true
}

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
