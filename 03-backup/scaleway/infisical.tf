resource "infisical_secret_folder" "backup" {
  project_id       = var.infisical_workspace_id
  environment_slug = var.infisical_env_slug
  folder_path      = "/"
  name             = trimprefix(var.infisical_folder_path, "/")
  description      = "Backup workload credentials (managed by terraform: 03-backup/scaleway/)."
}

resource "infisical_secret" "access_key" {
  name         = "BACKUP_ACCESS_KEY"
  value        = scaleway_iam_api_key.workload.access_key
  env_slug     = var.infisical_env_slug
  workspace_id = var.infisical_workspace_id
  folder_path  = infisical_secret_folder.backup.path
}

resource "infisical_secret" "secret_key" {
  name         = "BACKUP_SECRET_KEY"
  value        = scaleway_iam_api_key.workload.secret_key
  env_slug     = var.infisical_env_slug
  workspace_id = var.infisical_workspace_id
  folder_path  = infisical_secret_folder.backup.path
}
