# Bootstrap Tailscale API key, generated once by hand (Settings > Keys in
# the admin console -- a personal API key acting with the creating
# account's own admin rights, simpler to generate than scoping an OAuth
# client for a credential only ever used locally, occasionally, by a
# human). Same chicken-and-egg shape every other bootstrap root in this
# repo has (e.g. 01-iam/bootstrap/aws needing an initial identity before
# Terraform can manage anything). See README's "Bootstrap credentials"
# section.
variable "api_key" {
  description = "Bootstrap Tailscale API key. Per-developer, from a gitignored *.auto.tfvars -- see README. Expires (Tailscale-enforced, ~90 days) -- regenerate and rewrite the tfvars file when it does."
  type        = string
  sensitive   = true
}

variable "tailnet" {
  description = "Tailscale tailnet identifier. Leave null (default) to use the tailnet that owns the API key -- correct for a single-tailnet personal account."
  type        = string
  default     = null
}

# --- Federated identities (visible config, set in env/*.tfvars) ---

# One entry per OIDC trust. Add a future identity by adding a map entry --
# no new .tf resources. The map key is stable (it is the resource address),
# so renaming a key means a `moved` block, not just an edit.
variable "federated_identities" {
  description = "Tailscale federated identities (OIDC workload identity federation), keyed by a stable name."
  type = map(object({
    description = string
    issuer      = string       # OIDC issuer Tailscale validates tokens against
    subject     = string       # `sub` claim pattern allowed to use this identity
    audience    = string       # Free-form, chosen by us: `audience` is Optional but NOT Computed in the provider schema, so leaving it unset would drift
    tags        = list(string) # Tags the joining node is assigned (must be in tagOwners -- derived below)
    scopes      = optional(list(string), ["auth_keys"])
    # Grant tailnet members network reach + SSH to nodes carrying these tags
    # (what live debugging needs). Set false for an identity whose nodes
    # shouldn't be reachable by members.
    member_ssh = optional(bool, true)
  }))

  validation {
    condition     = alltrue([for v in values(var.federated_identities) : alltrue([for t in v.tags : startswith(t, "tag:")])])
    error_message = "Every tag must start with \"tag:\"."
  }
}
