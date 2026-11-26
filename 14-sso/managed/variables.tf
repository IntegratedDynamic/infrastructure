variable "authentik_url" {
  type        = string
  description = "authentik API base URL the provider talks to. Defaults to the in-cluster Service (reachable from the Crossplane Workspace pod without any DNS)."
  default     = "http://authentik-server.authentik.svc:80"
}

variable "authentik_token" {
  type        = string
  sensitive   = true
  description = "API token of authentik's built-in akadmin (AUTHENTIK_BOOTSTRAP_TOKEN). Supplied as TF_VAR_authentik_token, never committed."
}

variable "domain" {
  type        = string
  description = "Platform base domain, e.g. staging.scalepack.fr. authentik is served at sso<host_suffix>.<domain>, every protected app at <host_prefix><host_suffix>.<domain>."
}

variable "host_suffix" {
  type        = string
  description = "Per-cluster hostname suffix (var.env_suffix of 10-cluster/scaleway). Empty on the stable workspace; set on ephemeral clusters so their hostnames don't collide with production's."
  default     = ""
}

variable "groups" {
  type = map(object({
    # Full authentik administration (Admin interface included) for its members.
    is_superuser = optional(bool, false)
  }))
  description = "Groups to declare. Membership is NOT managed here: users are added to groups by hand (or invitation), by design -- this root owns the structure, not the people."
}

variable "invitation_groups" {
  type        = set(string)
  default     = []
  description = "Groups people can join through an invitation link: one enrollment flow `invitation-<group>` each (invitations.tf). Must be declared in var.groups and must not be superuser groups."

  validation {
    condition     = alltrue([for g in var.invitation_groups : contains(keys(var.groups), g)])
    error_message = "Every invitation group must be declared in var.groups."
  }

  validation {
    condition     = alltrue([for g in var.invitation_groups : !try(var.groups[g].is_superuser, false)])
    error_message = "An invitation link must never grant a superuser group: whoever holds the link would become an authentik administrator."
  }
}

variable "applications" {
  type = map(object({
    name        = string
    host_prefix = string
    groups      = list(string)
    # Free-text section the tile is filed under on the "My applications" page.
    section = optional(string, "")
  }))
  description = <<-EOT
    Applications gated by authentik's forward-auth (one proxy provider per
    app, "single application" mode, so each app carries its OWN access policy).
    `groups` are the groups allowed to see AND launch the app: a group binding
    on the application, which is also what decides whether its tile shows on a
    user's "My applications" page. An app with no group is visible to every
    authenticated user (authentik's own default for an unbound application).
  EOT
}

variable "github_client_id" {
  type        = string
  description = "Client ID of the GitHub OAuth App behind the \"GitHub\" login source (kv/apps/authentik/credentials, github-client-id). Supplied as TF_VAR_github_client_id by the Workspace. Empty or the \"REPLACE_ME\" placeholder disables the source entirely."
  default     = ""
}

variable "github_client_secret" {
  type        = string
  sensitive   = true
  description = "Client secret of that OAuth App (kv/apps/authentik/credentials, github-client-secret). Supplied as TF_VAR_github_client_secret, never committed."
  default     = ""
}

variable "github_org" {
  type        = string
  description = "GitHub organization whose members may log in. Only active members of it are put in any group, so everyone else gets an account with no access."
  default     = ""
}

variable "github_member_group" {
  type        = string
  description = "authentik group every active member of github_org is put in. Must be one of var.groups."
  default     = "platform-users"
}

variable "github_team_groups" {
  type        = map(string)
  description = "GitHub team slug (in github_org) -> authentik group. A member of the team is put in that group on top of github_member_group. Groups are matched by NAME, so they must be declared in var.groups."
  default     = {}
}

variable "oidc_clients" {
  type = map(object({
    name          = string
    client_id     = string
    client_type   = optional(string, "confidential")
    redirect_uris = list(string)
    groups        = list(string)
    launch_url    = optional(string, "")
    section       = optional(string, "")
    hide_tile     = optional(bool, false)
  }))
  default     = {}
  description = <<-EOT
    OIDC clients of the platform's own apps. The map key is the application
    slug and so part of the client's issuer URL
    (https://sso.<domain>/application/o/<key>/). `groups` are the groups allowed
    to use the app (a binding on the application, which also decides whose
    "My applications" page lists it); what the app then grants inside itself
    (admin vs read-only...) is the app's own mapping of the `groups` claim.
    `redirect_uris` are matched exactly.
  EOT
}

variable "oidc_client_secrets" {
  type        = map(string)
  sensitive   = true
  default     = {}
  description = "Client secret of each confidential client in var.oidc_clients, keyed like it. Supplied as TF_VAR_oidc_client_secrets by the Workspace (the same secrets the Dex static clients used), never committed."
}

# --- access report (reporting.tf) -------------------------------------------

variable "grafana_url" {
  type        = string
  default     = "http://grafana-wake.monitoring.svc:8080/"
  description = "Grafana API the access report is declared into. Defaults to the in-cluster wake-up Service (Grafana scales to zero)."
}

variable "grafana_admin_password" {
  type        = string
  sensitive   = true
  default     = ""
  description = "Grafana's admin password (kv/apps/grafana/admin), supplied as TF_VAR_grafana_admin_password. Empty disables the access report."
}

variable "reporting_db_host" {
  type        = string
  default     = "authentik-postgres.authentik.svc:5432"
  description = "authentik's PostgreSQL, as reached by Grafana."
}

variable "reporting_db_password" {
  type        = string
  sensitive   = true
  default     = ""
  description = "Password of the read-only PostgreSQL role `grafana_reader` (kv/apps/authentik-reporting/eso-generated; the role is created by the gitops repo's authentik chart), supplied as TF_VAR_reporting_db_password. Empty disables the access report."
}
