variable "infisical_client_id" {
  type = string
}

variable "infisical_client_secret" {
  type = string
}

variable "gitops_revision" {
  type    = string
  default = "main"
}

variable "argocd_admin_password_hash" {
  description = "Pre-computed bcrypt hash of the ArgoCD admin password. When set, Infisical is not consulted."
  type        = string
  # default     = ""
}

