# Trust anchor for Crossplane's own provider-opentofu Workspace controller
# to self-bootstrap 11-secrets/openbao/managed, its own OTHER root
# (infra#115 follow-up, 2026-09-30, part 3).
#
# The chicken-and-egg: Crossplane's Workspace is managed/'s own unattended
# applier. Its trust anchor (a Kubernetes-auth role bound to its
# ServiceAccount) has to exist in OpenBao BEFORE it can authenticate — but
# if that role were declared inside managed/ itself, creating it would
# require a successful managed/ apply, which requires authenticating
# first. A human always has an escape hatch for managed/'s own first apply
# (var.root_token there) — an unattended Workspace never does. This root
# breaks that loop, minimally: it creates ONLY what's needed for Crossplane
# to authenticate at all, nothing else. Everything else OpenBao needs
# (KV mount, the human OIDC role, secret content, the OTHER two Kubernetes-
# auth roles that reuse this SAME mount by literal path — snapshot,
# external-secrets) lives in managed/, applied by a human (this root's own
# var.root_token) the first time, and by either a human (OIDC) or
# Crossplane (Kubernetes auth, now bootstrapped) from then on.
#
# This replaces the AppRole identity this root used to mint (deleted along
# with the AppRole itself, part 2 of this same follow-up) — investigating
# that live break turned up that AppRole's actual justification never
# applied to either of managed/'s real execution contexts (an admin's
# laptop is a human, the Crossplane Workspace is now Kubernetes auth) — see
# managed/version.tf's own vault_auth_method comment for the full incident.
# What's left of the ORIGINAL "human/admin-applied trust anchor" shape is
# this: still needed, just for a different, narrower reason — closing
# Crossplane's OWN bootstrap loop, not standing in as managed/'s everyday
# identity the way AppRole used to.
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

    # Auth backend config/roles (e.g. auth/kubernetes/role/*) — not the
    # unauthenticated login sub-paths, which policies don't gate anyway.
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

# Mounted + configured here, not in managed/, specifically because
# Crossplane's own role (below) needs it to exist before managed/ is ever
# successfully applied. managed/'s OTHER Kubernetes-auth roles (snapshot,
# external-secrets) reference this SAME mount by its literal path
# ("kubernetes"), not a resource reference — cross-root, different state.
resource "vault_auth_backend" "kubernetes" {
  type = "kubernetes"
  path = "kubernetes"
}

resource "vault_kubernetes_auth_backend_config" "kubernetes" {
  backend                = vault_auth_backend.kubernetes.path
  kubernetes_host        = "https://kubernetes.default.svc"
  disable_iss_validation = true
}

# provider-opentofu/crossplane-system — bound to Crossplane's own Workspace
# controller ServiceAccount (gitops repo
# services/platform/crossplane/chart's DeploymentRuntimeConfig pins that
# name deterministically, not revision-hashed, specifically so this
# binding survives a provider upgrade). The ONE role this root exists to
# create — everything above it (the policy, the mount) is scaffolding this
# role needs to exist at all.
resource "vault_kubernetes_auth_backend_role" "crossplane" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "crossplane"
  bound_service_account_names      = ["provider-opentofu"]
  bound_service_account_namespaces = ["crossplane-system"]
  token_policies                   = [vault_policy.terraform.name]
  token_ttl                        = 3600
}
