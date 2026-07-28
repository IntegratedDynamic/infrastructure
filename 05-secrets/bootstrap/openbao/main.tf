# Trust anchor for a future Terraform-managed OpenBao configuration: an AppRole
# identity scoped to *structure* (mounts, auth methods, ACL policies), not to any
# KV data. AppRole is Vault/OpenBao's machine-auth mechanism — OIDC here is
# wired for human login only (see gitops repo platform/scaleway/dex.yml).
resource "vault_auth_backend" "approle" {
  type = "approle"
  path = "approle"
}

# This identity is meant to bootstrap OpenBao from scratch, end to end — not
# just its shape (mounts, auth methods, policies) but the secret values living
# inside too, at least the ones OpenBao's own config owns the lifecycle of
# (Dex client secrets, Grafana's admin password, etc). Deliberately no
# `delete` on kv/data|metadata/* though: this identity can create/own secret
# content, but destroying it isn't part of "bootstrap/reconcile". sys/mounts/*
# and sys/auth/* are Vault "root-protected" endpoints, hence the explicit
# `sudo` capability there.
resource "vault_policy" "terraform" {
  name = "terraform"

  policy = <<-EOT
    path "sys/mounts" {
      capabilities = ["read", "list"]
    }

    path "sys/mounts/*" {
      capabilities = ["create", "read", "update", "delete", "list", "sudo"]
    }

    path "sys/auth" {
      capabilities = ["read", "list"]
    }

    path "sys/auth/*" {
      capabilities = ["create", "read", "update", "delete", "list", "sudo"]
    }

    # Auth backend config/roles (e.g. auth/kubernetes/role/*, auth/approle/role/*)
    # — not the unauthenticated login sub-paths, which policies don't gate anyway.
    path "auth/*" {
      capabilities = ["create", "read", "update", "delete", "list"]
    }

    path "sys/policies/acl" {
      capabilities = ["list"]
    }

    path "sys/policies/acl/*" {
      capabilities = ["create", "read", "update", "delete", "list"]
    }

    # KV v2 secret data this identity owns the lifecycle of. No "delete" —
    # this identity creates/reconciles secret content, it doesn't destroy it.
    path "kv/data/apps/*" {
      capabilities = ["create", "read", "update", "list"]
    }

    path "kv/metadata/apps/*" {
      capabilities = ["create", "read", "update", "list"]
    }
  EOT
}

resource "vault_approle_auth_backend_role" "terraform" {
  backend        = vault_auth_backend.approle.path
  role_name      = "terraform"
  token_policies = [vault_policy.terraform.name]
  token_ttl      = var.token_ttl_seconds
  token_max_ttl  = var.token_max_ttl_seconds
  secret_id_ttl  = var.secret_id_ttl_days * 24 * 3600
}

# Generated once at apply time; state-only, per the repo's bootstrap model (same
# pattern as the Scaleway API key in 01-iam/bootstrap/scaleway). Rotate by
# tainting this resource — see README.
resource "vault_approle_auth_backend_role_secret_id" "terraform" {
  backend   = vault_auth_backend.approle.path
  role_name = vault_approle_auth_backend_role.terraform.role_name
}
