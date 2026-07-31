# Validation harness only — `terraform init` + `validate` + `plan` to sanity
# check the module's schema in isolation. Never `apply` this: it has no
# backend and is not a real root.

terraform {
  required_providers {
    scaleway = {
      source  = "scaleway/scaleway"
      version = "~> 2.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}

provider "scaleway" {}

# Single-policy case (kubernetes/velero/external-dns shape).
module "single_policy" {
  source = "../.."

  application_name = "example-single"
  project_id        = "00000000-0000-0000-0000-000000000000"

  policies = {
    default = {
      name = "example-single-objects"
      rules = [
        {
          project_ids           = ["00000000-0000-0000-0000-000000000000"]
          permission_set_names  = ["ObjectStorageObjectsRead", "ObjectStorageObjectsWrite"]
        }
      ]
    }
  }
}

# Dual-policy, mixed project+org rule case (github-ci shape).
module "dual_policy" {
  source = "../.."

  application_name = "example-dual"
  project_id        = "00000000-0000-0000-0000-000000000000"

  policies = {
    cluster_management = {
      name = "example-cluster-management"
      rules = [
        {
          project_ids           = ["00000000-0000-0000-0000-000000000000"]
          permission_set_names  = ["KubernetesFullAccess"]
        }
      ]
    }
    backup_management = {
      name = "example-backup-management"
      rules = [
        {
          project_ids           = ["00000000-0000-0000-0000-000000000000"]
          permission_set_names  = ["ObjectStorageBucketsRead", "ObjectStorageBucketsWrite"]
        },
        {
          organization_id       = "00000000-0000-0000-0000-000000000000"
          permission_set_names  = ["IAMApplicationManager", "IAMPolicyManager"]
        }
      ]
    }
  }
}
