# "Who has access to what": a Grafana dashboard reading authentik's database.
# authentik's Admin interface answers it one user, group or application at a
# time; this is the one page crossing all users with all applications.
#
# Read path: Grafana -> authentik's PostgreSQL as `grafana_reader`, a read-only
# role holding column-level grants on exactly what the dashboard shows (no
# password hashes, tokens, client secrets or invitation links). The role and its
# grants belong to the gitops repo (services/platform/authentik/chart,
# reporting-role.yaml); its password is ESO-generated.
#
# WHO CAN READ IT: the dashboard's folder is admin-only. The DATA SOURCE cannot
# be: open-source Grafana has no per-data-source permissions, so any signed-in
# Grafana user (platform-users too) can query it through Grafana's API, and read
# what the role reads: the directory of users, e-mails, groups and access.
#
# The access computation re-states authentik's rule for what this platform uses
# (group and user bindings, nested groups, negation, expiry, any/all mode).
# A binding to an expression policy cannot be evaluated in SQL and shows as "?".
#
# Edit dashboards/access.json directly.

locals {
  access_report_enabled = nonsensitive(var.grafana_admin_password != "" && var.reporting_db_password != "")
}

resource "grafana_data_source" "authentik" {
  count = local.access_report_enabled ? 1 : 0

  type     = "grafana-postgresql-datasource"
  name     = "authentik (read-only)"
  uid      = "authentik-db"
  url      = var.reporting_db_host
  username = "grafana_reader"

  json_data_encoded = jsonencode({
    database        = "authentik"
    sslmode         = "disable" # in-cluster Service, the server offers no TLS
    postgresVersion = 1700
    maxOpenConns    = 3 # the role itself is limited to 5
  })
  secure_json_data_encoded = jsonencode({
    password = var.reporting_db_password
  })
}

resource "grafana_folder" "access" {
  count = local.access_report_enabled ? 1 : 0

  uid   = "sso-access"
  title = "Access (admins)"
}

# Replaces the folder's default Viewer/Editor permissions: admins only.
resource "grafana_folder_permission" "access" {
  count = local.access_report_enabled ? 1 : 0

  folder_uid = grafana_folder.access[0].uid

  permissions {
    role       = "Admin"
    permission = "Admin"
  }
}

resource "grafana_dashboard" "access" {
  count = local.access_report_enabled ? 1 : 0

  folder      = grafana_folder.access[0].uid
  config_json = file("${path.module}/dashboards/access.json")
  overwrite   = true

  depends_on = [grafana_folder_permission.access]
}
