# 0 = never expires (Grafana's own sentinel for seconds_to_live) — unlike
# secret_id_ttl_days in 05-secrets/openbao/bootstrap, no forced rotation
# window by default for this low-stakes, single-consumer identity. Set a
# positive value here to opt into rotation.
variable "service_account_token_ttl_days" {
  description = "Days before the terraform service account token expires. 0 = never expires."
  type        = number
  default     = 0
}

# ── Cross-root state reads (Scaleway state buckets, see 00-foundation/scaleway) ──

variable "openbao_managed_state_bucket" {
  description = "Scaleway bucket holding 05-secrets/openbao/managed's remote state."
  type        = string
}

variable "openbao_managed_state_key" {
  description = "Object key for 05-secrets/openbao/managed's state within openbao_managed_state_bucket."
  type        = string
}

# See version.tf's provider "grafana" block for why this is a variable.
variable "grafana_url" {
  description = "URL the grafana provider authenticates against."
  type        = string
  default     = "https://grafana.scalepack.fr/"
}
