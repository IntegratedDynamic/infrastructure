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

# ── Cross-root state reads (Scaleway state buckets, see 00-foundation/scaleway) ──
# Defaulted (unlike other roots' env/*.tfvars-required equivalents) since this
# root's own vars come from a per-developer, gitignored nico.auto.tfvars file
# — defaults keep it working without every developer having to add these.

variable "backup_scaleway_state_bucket" {
  description = "Scaleway bucket holding 03-storage/scaleway's remote state."
  type        = string
  default     = "id-terraform-state-03-storage-scaleway"
}

variable "backup_scaleway_state_key" {
  description = "Object key for 03-storage/scaleway's state within backup_scaleway_state_bucket."
  type        = string
  default     = "03-storage/scaleway/03-storage-scaleway-dev/terraform.tfstate"
}

variable "openbao_unseal_aws_state_bucket" {
  description = "Scaleway bucket holding 02-encryption/aws's remote state."
  type        = string
  default     = "id-terraform-state-02-encryption-aws"
}

variable "openbao_unseal_aws_state_key" {
  description = "Object key for 02-encryption/aws's state within openbao_unseal_aws_state_bucket."
  type        = string
  default     = "02-encryption/aws/02-encryption-aws-dev/terraform.tfstate"
}

