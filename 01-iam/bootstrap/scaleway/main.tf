# GitHub Actions CI identity for the IntegratedDynamic/infrastructure repo.
# Two policies on one application: cluster-management (Kubernetes/VPC/
# PrivateNetwork/Instances, to create/destroy the Kapsule cluster) and
# backup-management (Object Storage + IAM application/policy management, so
# the CI can also provision the storage domain's buckets and their scoped
# workload identities).
module "ci_identity" {
  source = "../../../modules/scaleway-machine-identity"

  application_name        = "github-ci"
  application_description = "GitHub Actions CI for the IntegratedDynamic/infrastructure repo (managed by terraform: 01-iam/bootstrap/scaleway/)."

  policies = {
    cluster_management = {
      name        = "github-ci-cluster-management"
      description = "Kubernetes/VPC/PrivateNetwork/Instances management for the GitHub Actions CI application, project-scoped."
      rules = [
        {
          project_ids = [var.project_id]
          # InstancesFullAccess added 2026-08-25: 10-cluster/scaleway's
          # scaleway_instance_security_group.cluster_nodes needs it (Instance
          # API, not covered by VPC/Kubernetes/PrivateNetworks) -- confirmed
          # live, "insufficient permissions: read compute_security_groups" on
          # a plan/apply against an already-existing cluster. Never surfaced
          # before because CI had never successfully gotten this far.
          permission_set_names = ["VPCFullAccess", "KubernetesFullAccess", "PrivateNetworksFullAccess", "IPAMReadOnly", "InstancesFullAccess"]
        }
      ]
    }

    # Object Storage bucket + IAM workload identity management for the
    # storage domain CI workflow (03-storage/scaleway/). Bucket deletion is
    # blocked via prevent_destroy + absence of a destroy trigger in the CI
    # workflow (Scaleway bucket policies do not support s3:DeleteBucket).
    backup_management = {
      name        = "github-ci-backup-management"
      description = "Object Storage bucket + IAM workload identity management for the storage domain CI workflow (03-storage/scaleway/)."
      rules = [
        {
          project_ids = [var.project_id]
          permission_set_names = [
            "ObjectStorageBucketsRead",
            "ObjectStorageBucketsWrite",
            "ObjectStorageObjectsRead",
            "ObjectStorageObjectsWrite",
          ]
        },
        # IAM permission sets are organization-scoped — they cannot be
        # combined with project_ids in the same rule.
        {
          organization_id = var.organization_id
          permission_set_names = [
            "IAMApplicationManager",
            "IAMPolicyManager",
          ]
        }
      ]
    }
  }

  project_id            = var.project_id
  api_key_description   = "Consumed from GitHub Actions secrets (SCW_ACCESS_KEY / SCW_SECRET_KEY)."
  api_key_rotation_days = var.api_key_rotation_days
}
