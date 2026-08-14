# No built-in expiry enforced by Grafana on service account tokens by
# default (seconds_to_live = 0/null means never expire) — this is a repo
# convention, not a platform requirement, mirroring secret_id_ttl_days in
# 05-secrets/openbao/bootstrap.
variable "service_account_token_ttl_days" {
  description = "Rotation window (days) for the terraform service account token."
  type        = number
  default     = 90
}
