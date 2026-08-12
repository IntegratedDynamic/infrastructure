terraform {
  backend "s3" {
    bucket               = "id-terraform-state20260612164136440800000001"
    region               = "eu-west-3"
    workspace_key_prefix = "secrets/managed/openbao"
    key                  = "terraform.tfstate"
    encrypt              = true
    use_lockfile         = true
  }

  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }
}

# role_id/secret_id for the `terraform` AppRole — read straight from
# 05-secrets/openbao/bootstrap's own state instead of a hand-copied variable.
# Safe to reference from the provider block below: this data source has no
# dependency on the vault provider itself (it's a plain S3 backend read), so
# there's no ordering cycle — same category of pattern as
# 10-cluster/scaleway/version.tf's kubernetes/helm providers reading straight
# off a resource attribute.
data "terraform_remote_state" "openbao_bootstrap" {
  backend = "s3"
  config = {
    bucket = "id-terraform-state20260612164136440800000001"
    region = "eu-west-3"
    key    = "secrets/bootstrap/openbao/05-secrets-openbao/terraform.tfstate"
  }
}

# Authenticates as the `terraform` AppRole from 05-secrets/openbao/bootstrap —
# this root is the machine identity that role exists for. Address hardcoded,
# not read from VAULT_ADDR: OpenBao's own CLI populates BAO_ADDR/BAO_TOKEN,
# not Vault's VAULT_ADDR/VAULT_TOKEN, so relying on the env var is a trap (see
# the bootstrap root's version.tf/README for the incident this came from).
provider "vault" {
  # Same hostname as OpenBao's public route, on purpose — not a fallback,
  # the actual mechanism: split-DNS (the tunnel's dns sidecar, gitops
  # repo's services/platform/wireguard/config) resolves this to the
  # WireGuard tunnel's own address (04-vpn/wireguard) while it's up,
  # routing privately through Envoy Gateway's real Service (proxy-gateway
  # sidecar) instead of the public internet. Same address either way —
  # bring the tunnel up first (`wg-quick up <peer_conf_paths output>`), or
  # this just hits the real public route (fine; that's still there for
  # human OIDC/UI login, this provider just doesn't need it anymore).
  address = "https://openbao.scalepack.fr/"

  # Direct port-forward, independent of the tunnel/gateway path entirely.
  # Requires Kubernetes permissions to run `kubectl port-forward -n openbao openbao-0 8200:8200`
  # address = "http://127.0.0.1:8200/"

  auth_login {
    path = "auth/approle/login"
    parameters = {
      role_id   = data.terraform_remote_state.openbao_bootstrap.outputs.role_id
      secret_id = data.terraform_remote_state.openbao_bootstrap.outputs.secret_id
    }
  }
}

# Cluster connection for this root's own `kubernetes` provider — read
# straight off 10-cluster/scaleway's state instead of a hand-copied
# kubeconfig, same pattern as the vault provider's AppRole creds above.
# Needed for kubernetes_manifest.eso_cluster_secret_store in main.tf: the
# ClusterSecretStore is the Kubernetes-side half of the
# vault_kubernetes_auth_backend_role.external_secrets relationship this
# root already owns the other half of — used to live in the gitops repo's
# openbao-init chart, moved here 2026-08-12 (see main.tf's comment) so both
# halves are managed together instead of one being GitOps-synced against a
# prerequisite (the auth backend role) that was actually Terraform-owned
# the whole time.
data "terraform_remote_state" "cluster_scaleway" {
  backend = "s3"
  config = {
    bucket = "id-terraform-state20260612164136440800000001"
    region = "eu-west-3"
    key    = "cluster/scaleway/02-cluster-staging/terraform.tfstate"
  }
}

provider "kubernetes" {
  host                   = data.terraform_remote_state.cluster_scaleway.outputs.cluster_host
  token                  = data.terraform_remote_state.cluster_scaleway.outputs.cluster_token
  cluster_ca_certificate = base64decode(data.terraform_remote_state.cluster_scaleway.outputs.cluster_ca_certificate)
}
