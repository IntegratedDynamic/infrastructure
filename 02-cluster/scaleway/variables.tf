# Infisical provide many way to authenticate.
# You can use `infisical_client_id` and `infisical_client_secret` when running terraform locally
# Or use `infisical_oidc_identity_id` when OIDC integration is available.
variable "infisical_client_id" {
  type    = string
  default = ""
}

variable "infisical_client_secret" {
  type      = string
  default   = ""
  sensitive = true
}

variable "infisical_oidc_identity_id" {
  description = "Infisical OIDC machine-identity ID. When set, the provider authenticates via GitHub-OIDC; when empty, via universal auth."
  type        = string
  default     = ""
}

variable "k8s_version" {
  type    = string
  default = "1.35"
}

variable "node_count" {
  type    = number
  default = 1
}

variable "cluster_name" {
  description = "The cluster name"
  type        = string
  default     = "scaleway-homelab"
}

variable "gitops_revision" {
  type    = string
  default = "main"
}

variable "update_kubeconfig" {
  type = bool
  default = false
  description = "Set to true when using locally to automatically update you ~/.kube/config. Require `kubectl` and `scw` installed & configured."
}
