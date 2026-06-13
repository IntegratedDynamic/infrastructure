# Dedicated, least-privilege identity for the Terraform CI/CD pipeline to
# authenticate to Scaleway and run `terraform apply/destroy` on cluster/scaleway.
# This is distinct from the read-only github-ci/ identity: it has its own
# application, policy, key and state, so it can be rotated/revoked in isolation.
#
# The keyless GitHub-OIDC -> Scaleway flow isn't possible yet (Scaleway IAM is
# not an OIDC relying party — see README), so we use Scaleway's supported
# pattern: a scoped, independently-revocable API key consumed from GH secrets.

resource "scaleway_iam_application" "terraform_ci" {
  name        = "terraform-ci"
  description = "Terraform CI/CD for the IntegratedDynamic/infrastructure repo — applies cluster/scaleway (managed by terraform: terraform-ci/)."
}

# Least privilege for `cluster/scaleway`, scoped to a single project:
#   ObjectStorageReadWrite — R/W the S3 Terraform state backend
#   KubernetesFullAccess   — scaleway_k8s_cluster + scaleway_k8s_pool
#   VPCFullAccess          — scaleway_vpc_private_network
# The Kubernetes/Helm providers authenticate via the cluster kubeconfig and the
# Infisical provider via its own creds, so neither needs an IAM permission set.
resource "scaleway_iam_policy" "terraform_ci" {
  name           = "terraform-ci-cluster-management"
  description    = "Object Storage R/W + Kubernetes + VPC for the Terraform CI application, project-scoped."
  application_id = scaleway_iam_application.terraform_ci.id

  rule {
    project_ids          = [var.project_id]
    permission_set_names = ["ObjectStorageReadWrite"]
  }

  rule {
    project_ids          = [var.project_id]
    permission_set_names = ["KubernetesFullAccess"]
  }

  rule {
    project_ids          = [var.project_id]
    permission_set_names = ["VPCFullAccess"]
  }
}

# The org enforces an expiry on every API key, and `expires_at` is ForceNew, so
# the key inherently rotates when the expiry moves. time_rotating makes that
# concrete and self-renewing: the timestamp holds steady until the window
# elapses, then the next apply pushes it forward and rotates the key (re-run
# `gh secret set` afterwards — see README).
resource "time_rotating" "api_key" {
  rotation_days = var.api_key_rotation_days
}

resource "scaleway_iam_api_key" "terraform_ci" {
  application_id = scaleway_iam_application.terraform_ci.id
  description    = "Consumed from GitHub Actions secrets (TF_SCW_ACCESS_KEY / TF_SCW_SECRET_KEY)."

  # Bakes the project into the key so the state backend and Scaleway resources
  # resolve the right scope without the workflow passing a project ID.
  default_project_id = var.project_id

  expires_at = time_rotating.api_key.rotation_rfc3339
}

# ── Write the key into Infisical ────────────────────────────────────────────
# GitHub secrets themselves are still set manually via `gh secret set` (see
# README) — automating that push is deferred to avoid a GitHub token here.

# infisical_secret does not create missing folders, so the CI folder must exist
# first. var.infisical_folder_path is "/<name>"; create that name under root.
resource "infisical_secret_folder" "ci" {
  project_id       = var.infisical_workspace_id
  environment_slug = var.infisical_env_slug
  folder_path      = "/"
  name             = trimprefix(var.infisical_folder_path, "/")
  description      = "CI secrets for GitHub Actions (shared /ci folder)."
}

resource "infisical_secret" "tf_scw_access_key" {
  name         = "TF_SCW_ACCESS_KEY"
  value        = scaleway_iam_api_key.terraform_ci.access_key
  env_slug     = var.infisical_env_slug
  workspace_id = var.infisical_workspace_id
  folder_path  = infisical_secret_folder.ci.path
}

resource "infisical_secret" "tf_scw_secret_key" {
  name         = "TF_SCW_SECRET_KEY"
  value        = scaleway_iam_api_key.terraform_ci.secret_key
  env_slug     = var.infisical_env_slug
  workspace_id = var.infisical_workspace_id
  folder_path  = infisical_secret_folder.ci.path
}
