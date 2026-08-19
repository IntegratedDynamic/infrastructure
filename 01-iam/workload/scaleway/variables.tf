variable "project_id" {
  description = "Scaleway project ID for IAM resource scoping."
  type        = string
}

# One Scaleway machine identity per entry, via
# modules/scaleway-machine-identity. Single policy per identity — this domain
# is for simple scoped workload credentials (like external-dns), not CI trust
# anchors that might need several policies (see 01-iam/bootstrap/scaleway for
# that shape instead).
variable "identities" {
  description = "Map of identity key => config."
  type = map(object({
    purpose               = string
    policy_description    = string
    api_key_rotation_days = optional(number, 365)
    rules = list(object({
      project_ids          = optional(list(string))
      organization_id      = optional(string)
      permission_set_names = list(string)
    }))
  }))
}
