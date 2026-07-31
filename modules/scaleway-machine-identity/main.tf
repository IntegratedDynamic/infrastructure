resource "scaleway_iam_application" "this" {
  name        = var.application_name
  description = var.application_description
}

resource "scaleway_iam_policy" "this" {
  for_each = var.policies

  name           = each.value.name
  description    = each.value.description
  application_id = scaleway_iam_application.this.id

  dynamic "rule" {
    for_each = each.value.rules
    content {
      project_ids          = rule.value.project_ids
      organization_id      = rule.value.organization_id
      permission_set_names = rule.value.permission_set_names
    }
  }
}

# Scaleway requires every API key to carry an expiry. time_rotating keeps it
# self-renewing: the timestamp holds steady until the window elapses, then
# the next apply pushes it forward and rotates the key.
resource "time_rotating" "this" {
  rotation_days = var.api_key_rotation_days
}

resource "scaleway_iam_api_key" "this" {
  application_id      = scaleway_iam_application.this.id
  description         = var.api_key_description
  default_project_id  = var.project_id
  expires_at          = time_rotating.this.rotation_rfc3339
}
