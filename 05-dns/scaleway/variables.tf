variable "project_id" {
  description = "Scaleway project ID: where the identity lives and whose DNS zones it may edit."
  type        = string
}

variable "api_key_rotation_days" {
  description = "Rotation period of the identity's API key."
  type        = number
  default     = 365
}

variable "workspace_name" {
  description = <<-EOT
    Suffix of the identity's IAM application/policy name, e.g.
    "05-dns-scaleway-main". live/root.hcl passes it:
    "<root path flattened>-<instance>". Changing it renames the live IAM resources
    (in place, no key rotation: Scaleway API keys are tied to application_id, not
    name).
  EOT
  type        = string
}
