# 0 = never expires (Grafana's own sentinel for seconds_to_live) — unlike
# secret_id_ttl_days in 05-secrets/openbao/bootstrap, no forced rotation
# window by default for this low-stakes, single-consumer identity. Set a
# positive value here to opt into rotation.
variable "service_account_token_ttl_days" {
  description = "Days before the terraform service account token expires. 0 = never expires."
  type        = number
  default     = 0
}
