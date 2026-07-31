variable "application_name" {
  description = "Name of the Scaleway IAM application (the machine identity itself)."
  type        = string
}

variable "application_description" {
  description = "Description of the IAM application."
  type        = string
  default     = ""
}

# Keyed by an arbitrary policy-purpose slug. One entry covers the common case
# (a single project-scoped rule); an identity that needs more than one policy
# object (e.g. one project-scoped + one org-scoped, or two independently
# named policies) adds more entries — this is a map of policies, not a
# single policy with a rule list, specifically so call sites with more than
# one `scaleway_iam_policy` today can be wrapped as a pure address rename.
variable "policies" {
  description = "Map of policy-purpose slug => policy definition. Each becomes its own scaleway_iam_policy, supporting one or more rule blocks."
  type = map(object({
    name        = string
    description = optional(string, "")
    rules = list(object({
      project_ids          = optional(list(string))
      organization_id      = optional(string)
      permission_set_names = list(string)
    }))
  }))
}

variable "project_id" {
  description = "Scaleway project ID the API key defaults to (default_project_id)."
  type        = string
}

variable "api_key_description" {
  description = "Description of the generated API key."
  type        = string
  default     = ""
}

variable "api_key_rotation_days" {
  description = "Lifetime (days) of the API key before terraform rotates it on the next apply. Scaleway requires every API key to carry an expiry."
  type        = number
  default     = 365
}
