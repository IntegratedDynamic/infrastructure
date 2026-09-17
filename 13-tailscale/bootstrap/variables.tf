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
