# # Infisical provide many way to authenticate.
# # You can use `infisical_client_id` and `infisical_client_secret` when running terraform locally
# # Or use `infisical_oidc_identity_id` when OIDC integration is available.
# variable "infisical_client_id" {
#   type    = string
#   default = ""
# }

# variable "infisical_client_secret" {
#   type      = string
#   default   = ""
#   sensitive = true
# }

# variable "infisical_oidc_identity_id" {
#   description = "Infisical OIDC machine-identity ID. When set, the provider authenticates via GitHub-OIDC; when empty, via universal auth."
#   type        = string
#   default     = ""
# }

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


# variable "gitops_revision" {
#   type    = string
#   default = "main"
# }

variable "argocd_admin_password_hash" {
  description = "Pre-computed bcrypt hash of the ArgoCD admin password. When set, Infisical is not consulted."
  type        = string
  # default     = ""
}

variable "scaleway_s3_secret_key" {
  description = "Scaleway S3 secret key for OpenBao backup bucket"
  type        = string
  sensitive   = true
  # default     = ""
}

variable "openbao_unseal_aws_access_key_id" {
  description = "AWS access key id OpenBao uses for KMS auto-unseal. From 03-backup/scaleway output `openbao_unseal_access_key_id`."
  type        = string
  sensitive   = true
  # default     = ""
}

variable "openbao_unseal_aws_secret_access_key" {
  description = "AWS secret access key OpenBao uses for KMS auto-unseal. From 03-backup/scaleway output `openbao_unseal_secret_access_key`."
  type        = string
  sensitive   = true
  # default     = ""
}
