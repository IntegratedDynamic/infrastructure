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

variable "install_kubeconfig" {
  description = "Merge this cluster into ~/.kube/config via `scw k8s kubeconfig install` for local DevX. Opt-in (set true in your *.auto.tfvars)."
  type        = bool
  default     = false
}

variable "kubeconfig_context_name" {
  description = "Clean context name to rename the installed kubeconfig entry to (scw names it <cluster>-<id> and has no rename flag)."
  type        = string
  default     = "scaleway-homelab"
}

variable "gitops_revision" {
  type    = string
  default = "main"
}
