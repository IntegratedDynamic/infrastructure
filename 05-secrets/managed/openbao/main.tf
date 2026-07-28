# --- KV v2: application/service secret data. Mounted manually 2026-07-20 (see
# gitops repo's PLAN-secrets-sync-github.md) — brought under Terraform here
# without changing its shape. The secret content itself is managed further
# down (kv/data/apps/* section).
resource "vault_mount" "kv" {
  path    = "kv"
  type    = "kv"
  options = { version = "2" }
}

# --- Kubernetes auth: lets in-cluster ServiceAccounts log in via their
# projected JWT. Mounted + configured manually 2026-07-15 for the snapshot
# agent, reused since 2026-07-20 for ESO.
resource "vault_auth_backend" "kubernetes" {
  type = "kubernetes"
  path = "kubernetes"
}

resource "vault_kubernetes_auth_backend_config" "kubernetes" {
  backend                = vault_auth_backend.kubernetes.path
  kubernetes_host        = "https://kubernetes.default.svc"
  disable_iss_validation = true
}

# openbao-snapshot/openbao — the raft snapshot agent bundled in the openbao
# Helm chart (gitops repo platform/scaleway/openbao.yml, snapshotAgent).
resource "vault_kubernetes_auth_backend_role" "snapshot" {
  backend                           = vault_auth_backend.kubernetes.path
  role_name                         = "snapshot"
  bound_service_account_names       = ["openbao-snapshot"]
  bound_service_account_namespaces  = ["openbao"]
  token_policies                    = [vault_policy.snapshot.name]
  token_ttl                         = 3600
}

# external-secrets/external-secrets — ESO's ClusterSecretStore
# (gitops repo apps/openbao-init/templates/clustersecretstore.yaml).
resource "vault_kubernetes_auth_backend_role" "external_secrets" {
  backend                           = vault_auth_backend.kubernetes.path
  role_name                         = "external-secrets"
  bound_service_account_names       = ["external-secrets"]
  bound_service_account_namespaces  = ["external-secrets"]
  token_policies                    = [vault_policy.eso_read.name]
  token_ttl                         = 3600
}

# --- OIDC auth: human login via Dex (gitops repo platform/scaleway/dex.yml,
# staticClients.openbao). oidc_client_secret is Terraform-generated (see
# random_password.openbao_client_secret below) — it's an arbitrary shared
# secret between OpenBao and Dex, nothing external constrains its value.
resource "vault_jwt_auth_backend" "oidc" {
  path               = "oidc"
  type               = "oidc"
  oidc_discovery_url = "https://auth.scalepack.fr"
  oidc_client_id     = "openbao"
  oidc_client_secret = random_password.openbao_client_secret.result
  default_role       = "admin"

  # TEMPORARY: identical letsencrypt-staging chain as gitops's
  # apps/grafana-config/templates/configmap-ca.yaml (fix/gateway-staging-ca) —
  # without it, OpenBao's server-side calls to Dex (token exchange, userinfo)
  # fail TLS verification. Remove both together once back on letsencrypt-prod.
  # chomp(): the live value has no trailing newline, but an HCL heredoc
  # always appends one — without chomp() this diffs forever.
  oidc_discovery_ca_pem = chomp(<<-EOT
    -----BEGIN CERTIFICATE-----
    MIIFDjCCAvagAwIBAgIQP62QbC8DAdGNbaR7NzBv3jANBgkqhkiG9w0BAQsFADBD
    MQswCQYDVQQGEwJVUzENMAsGA1UEChMESVNSRzElMCMGA1UEAxMcKFNUQUdJTkcp
    IFlvbmRlciBZYW0gUm9vdCBZUjAeFw0yNTA5MDMwMDAwMDBaFw0yODA5MDIyMzU5
    NTlaMEoxCzAJBgNVBAYTAlVTMRYwFAYDVQQKEw1MZXQncyBFbmNyeXB0MSMwIQYD
    VQQDExooU1RBR0lORykgRXJzYXR6IEVtbWVyIFlSMjCCASIwDQYJKoZIhvcNAQEB
    BQADggEPADCCAQoCggEBALVKXXQ+HfIdsroHx2TzhU3yBaocETY0MRoMHnS8CXUd
    X3GYyVh/rHVgbiN3Kl8uBUl9PULcgNL5ltGEaPbQpQ6Ydb3SCAUTkJYySlJRFTdd
    VnreV5Rv+zkcwWiyCVxjT1q10MDHQwIqKzfQqNK0bPn/RTUMgdGREPZsDdHaRjNS
    t3zTECX/UUkeKSGwRqQLmdpmT0cV1XgUnNdCSeZoChX/WGTy5ntWD7ejHUo/KQG5
    bhbD+XZ7Lm7us4Q5eBa10wgF9n7Q5JK/ZzwJ3Hx/o889zV+ZOlxWiQJi2K4E0DM9
    Oj3hPPHW6NEWNjVqvDOWd8WqlgrM06JKWukGgZzzieECAwEAAaOB9jCB8zAOBgNV
    HQ8BAf8EBAMCAYYwEwYDVR0lBAwwCgYIKwYBBQUHAwEwEgYDVR0TAQH/BAgwBgEB
    /wIBADAdBgNVHQ4EFgQURf/2+BQuZ/bfqVTyRaVnwNZqg2wwHwYDVR0jBBgwFoAU
    ULHXmAJQX9syRhtYwWhAciRvSsEwNgYIKwYBBQUHAQEEKjAoMCYGCCsGAQUFBzAC
    hhpodHRwOi8vc3RnLXlyLmkubGVuY3Iub3JnLzATBgNVHSAEDDAKMAgGBmeBDAEC
    ATArBgNVHR8EJDAiMCCgHqAchhpodHRwOi8vc3RnLXlyLmMubGVuY3Iub3JnLzAN
    BgkqhkiG9w0BAQsFAAOCAgEAhUIaqp4M/cqLqKqb5zyG9kJkGYzOWq2YHV558vCK
    CeLDkc12Jlll7u+AqkfkqwnLmqUHolHPQFNdL6HPW+f9lX68Kv4kaznRT7rxqXbX
    xWO5ylgpJibwDKmVt581OcyhleZ8fajL2LfcDbY24ivsWOwlKevbLBV2C+HKS+IM
    yvKxJovnbQsd2NfEiizPfrHXJAqyOv49yYeeE+eorvQHe8HJrNrYVjSs6PI51dbv
    Lac6+SwfiwbtGZqddS7t8IY+IfOksamRe78s4kiA99nLOEGrQXhxNZIryngqL8p8
    FKIi4UIC4Jez5wF8aSS/SG5IhCGbixgSYj/NpttpHOuWQFij54/eaFC8JXgDXafz
    +XXFuuTXpEzQdD0exRnRj5DU0GUR174KagSiYgK2ND0RAPMkwtdOND+2wCN6UC5x
    9fAjsDETMOe0aDAA1MKITiZ27MAxvxIDuAqTcVKYLu8NA37r2oC0k8ucAipMSUxt
    OYQ03+hl+7GCx14j9LYYG3PfVt/qD5wsp6ys2GcJX0GPj2FziTs0FoIb1zrKTD1v
    66xRtYZJIJmFfeSeZf7D0UcD3YA5Mbjmuz/6h43mws2nG/ZHbwPOtZV2N4cbXszu
    fEciE157FGkWTBabn3GeUd2uyMvuhbPKM6UajJ4TyjFBM8AVZyNPFR0IqRLZX64h
    DS4=
    -----END CERTIFICATE-----
    -----BEGIN CERTIFICATE-----
    MIIGKDCCBBCgAwIBAgIRAKYOL1Z3OCaTuowlAS/mVJgwDQYJKoZIhvcNAQELBQAw
    ZjELMAkGA1UEBhMCVVMxMzAxBgNVBAoTKihTVEFHSU5HKSBJbnRlcm5ldCBTZWN1
    cml0eSBSZXNlYXJjaCBHcm91cDEiMCAGA1UEAxMZKFNUQUdJTkcpIFByZXRlbmQg
    UGVhciBYMTAeFw0yNjA1MTMwMDAwMDBaFw0zMjA5MDIyMzU5NTlaMEMxCzAJBgNV
    BAYTAlVTMQ0wCwYDVQQKEwRJU1JHMSUwIwYDVQQDExwoU1RBR0lORykgWW9uZGVy
    IFlhbSBSb290IFlSMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAtp7v
    6tBp9gDpiGVLOjMs1eS9DgItpgFU9ReJwb/Sygs6q+6EUCxfi5qDOKkDldiVOtlj
    uwAFv8621qM4ukY6OmRBIA9hnCuunJlKNEjQfWArqwMOoo5iLZ4pq0UP4htWJluk
    OoVorSouK/3E1XWTR3ZwImIofC0+p2203TpDbThhgPzT/ZjvMUE24qQTBcQtJ8wI
    J7nz/k6B/NyM2+GmEMNFF11BtbUamVFJXMRi+KZeRoK/bQTAjePpY/0B1DDcqgQc
    wCb3sIOj5ysFUK7qJyca8Xk5bF8wFOFxGHKmRRPrMpb7tXdTXHlSymDCtUx98CCf
    wpr+7+vnHgaqsW5Yfr3AGt9P5SL+3hcmww4j0Xx6B3E4m0E+8g9mtJ1L1k7Caapw
    geRW0ghidKJmN+5gY3p2G7P8Hq4yWC+fmJy1OWCg6GDwZmCMQu/AMUawRV40AUYZ
    ZYBAeobZU/uKcmbWKUXuak1baZWp7oqjcsIDKxbMkg6KGjhLbVchHcYUslCoL+Aj
    ShfAA3n8WJ0cjU3p+BMkWjTKVuAfLYN/DA76CvfRWX02D+riGz3VsFXCw9k5mFE0
    zm+Vhc8xI3TWNhU6Qm6R1KrgCU2qOpgaJ8RlokUK3QFWrIdOAIQwO0leeyjTd/Me
    vsw62Bzg0rbQ1kS3h+eWBcBskNCFJKDujztGeCcCAwEAAaOB8zCB8DAOBgNVHQ8B
    Af8EBAMCAQYwEwYDVR0lBAwwCgYIKwYBBQUHAwEwDwYDVR0TAQH/BAUwAwEB/zAd
    BgNVHQ4EFgQUULHXmAJQX9syRhtYwWhAciRvSsEwHwYDVR0jBBgwFoAUtfNl8v6w
    CpIf+zx980SgrGMlwxQwNgYIKwYBBQUHAQEEKjAoMCYGCCsGAQUFBzAChhpodHRw
    Oi8vc3RnLXgxLmkubGVuY3Iub3JnLzATBgNVHSAEDDAKMAgGBmeBDAECATArBgNV
    HR8EJDAiMCCgHqAchhpodHRwOi8vc3RnLXgxLmMubGVuY3Iub3JnLzANBgkqhkiG
    9w0BAQsFAAOCAgEAaqpAP+MTuFW+J0X2ibDAFe2QBUxEVzxUri7lDLII/lcXkL93
    Vzu/fsfZL/D730It62cTSvVojEpBWP9AqGkVlldOjpKU2xag1D41CoRvkdgfFOd0
    ezk8afg6mDHv+aBnHr49AL7xb5SC3GUqj+bn5HURBQcGZJJhhTjzET4Wj1lQSZbP
    DqlS2WOxLiLnf5+EOVGjouJmJwFoodGOhEpAVxBWUY8B/9OGMzGAMBYeLMlEm4WV
    NO4J7URT4AL2+i+WAK/qhpVrl6Zc+x/NPcRbW3qm9xFwgqdNXxcDgPktWwVyEhlg
    3L9JrQ7y0s0b/or9Nbzj/Fng82IAputPDTMRHFRcsK2X7rShg2slHpWRrajd/j+u
    xmHm/x84V0I1MVqMKkPEW5PBkmoJICt5GtSX7UkI4NVGFDo8IFG/eTIFSEkCvBq5
    XEvE5lebNoFNSNKs7DfA6mhEpFmTJVONehdvRjPssmyTq21lY7w/9/4HTF2bEq8g
    G6dRn2ZJgqfmUxnBun2JdAADXArYsh1BkRtWQN+JjQIjiMNO3AhmHOXmkkW2gww2
    w8aH4OfRCndYYtw5Y60X9gNcpMRZOE2JjQG3ECZZb6EY5SEwPG+QxcRDOdQjZ4S6
    jgKO5JRQNGcnvW8cVYK5AMjgRGZE6V9IxECMeEwNEFA17qGcweG1Tb3IpYs=
    -----END CERTIFICATE-----
  EOT
  )
}

resource "vault_jwt_auth_backend_role" "admin" {
  backend   = vault_jwt_auth_backend.oidc.path
  role_name = "admin"
  role_type = "oidc"

  user_claim        = "email"
  groups_claim      = "groups"
  oidc_scopes       = ["groups", "email"]
  bound_claims_type = "string"
  bound_claims = {
    groups = "IntegratedDynamic:Admin"
  }
  allowed_redirect_uris = [
    "https://openbao.scalepack.fr/ui/vault/auth/oidc/oidc/callback",
    "http://localhost:8250/oidc/callback",
  ]

  token_policies = [vault_policy.admin.name]
  token_ttl      = 3600
}

# --- Policies ---

resource "vault_policy" "eso_read" {
  name = "eso-read"

  policy = <<-EOT
    path "kv/data/apps/*" {
      capabilities = ["read", "list"]
    }
    path "kv/metadata/apps/*" {
      capabilities = ["read", "list"]
    }
  EOT
}

resource "vault_policy" "snapshot" {
  name = "snapshot"

  policy = <<-EOT
    path "sys/storage/raft/snapshot" {
      capabilities = ["read"]
    }
  EOT
}

# Human OIDC-login admin — full sudo, bound to the `admin` OIDC role above,
# gated on the IntegratedDynamic:Admin GitHub group via Dex.
resource "vault_policy" "admin" {
  name = "admin"

  policy = <<-EOT
    path "*" {
      capabilities = ["create", "read", "update", "delete", "list", "sudo"]
    }
  EOT
}

# --- kv/data/apps/*: secret content, not just structure. Uses data_json_wo
# (write-only) + a static data_json_wo_version instead of data_json: the
# provider never reads secret values back from Vault to diff them (deliberate
# — avoids leaking plaintext into the state file), so the plain data_json
# attribute would show a spurious "changed" on every single plan. The
# write-only pair only triggers a write when data_json_wo_version is bumped,
# giving genuinely stable plans once applied. Bump the version to rotate.

data "terraform_remote_state" "dns_scaleway" {
  backend = "s3"
  config = {
    bucket = "id-terraform-state20260612164136440800000001"
    region = "eu-west-3"
    key    = "dns/scaleway/04-dns-scaleway/terraform.tfstate"
  }
}

# --- Arbitrary Dex<->client shared secrets: nothing external constrains
# these values, so Terraform generates and owns them outright — ArgoCD,
# Grafana, and Dex itself all read the *same* kv/apps/dex/credentials object
# below via their own ExternalSecret, so a rotation here propagates to every
# consumer through their existing refresh cycle, no separate copies to sync.
# To rotate: `terraform apply -replace=random_password.<name>` and bump
# vault_kv_secret_v2.dex_credentials's data_json_wo_version in the same change
# (the write-only field only re-writes to Vault when that version bumps).
resource "random_password" "argocd_client_secret" {
  length  = 32
  special = false
}

resource "random_password" "envoy_client_secret" {
  length  = 32
  special = false
}

resource "random_password" "grafana_client_secret" {
  length  = 32
  special = false
}

resource "random_password" "openbao_client_secret" {
  length  = 32
  special = false
}

resource "vault_kv_secret_v2" "dex_credentials" {
  mount = vault_mount.kv.path
  name  = "apps/dex/credentials"

  data_json_wo = jsonencode({
    "argocd-client-secret"  = random_password.argocd_client_secret.result
    "envoy-client-secret"   = random_password.envoy_client_secret.result
    "grafana-client-secret" = random_password.grafana_client_secret.result
    "openbao-client-secret" = random_password.openbao_client_secret.result
    "github-client-id"      = var.dex_github_connector["github-client-id"]
    "github-client-secret"  = var.dex_github_connector["github-client-secret"]
  })
  # Bumped from 1: content changed from "adopted existing values" to
  # "Terraform-generated" — this is a deliberate one-time rotation.
  data_json_wo_version = 2
}

# admin-password is arbitrary (previously openssl rand, per gitops commit
# 97aec22) — Terraform generates and owns it outright, same as the Dex client
# secrets above. admin-user stays a hardcoded literal, not a secret at all.
resource "random_password" "grafana_admin_password" {
  length  = 32
  special = false
}

resource "vault_kv_secret_v2" "grafana_admin" {
  mount = vault_mount.kv.path
  name  = "apps/grafana/admin"

  data_json_wo = jsonencode({
    "admin-user"     = "admin"
    "admin-password" = random_password.grafana_admin_password.result
  })
  # Bumped from 1: content changed from "adopted existing value" to
  # "Terraform-generated" — a deliberate one-time rotation.
  data_json_wo_version = 2
}

# SCW_ACCESS_KEY/SCW_SECRET_KEY sourced straight from infra's own IAM root
# (04-dns/scaleway) instead of a hand-copied variable — closes the "seed
# pending, no automated push yet" gap that root's own outputs.tf flags.
resource "vault_kv_secret_v2" "external_dns_scaleway_dns_credentials" {
  mount = vault_mount.kv.path
  name  = "apps/external-dns/scaleway-dns-credentials"

  data_json_wo = jsonencode({
    SCW_ACCESS_KEY = data.terraform_remote_state.dns_scaleway.outputs.workload_access_key
    SCW_SECRET_KEY = data.terraform_remote_state.dns_scaleway.outputs.workload_secret_key
  })
  data_json_wo_version = 1
}

resource "vault_kv_secret_v2" "secrets_sync_github_eso_private_key" {
  mount = vault_mount.kv.path
  name  = "apps/secrets-sync/github/eso-github-app-private-key"

  data_json_wo         = jsonencode(var.secrets_sync_github_eso_private_key)
  data_json_wo_version = 1
}

# --- GitHub secrets-sync content, scoped explicitly by org/repo/repo+env
# (see variable "secrets_sync_github") instead of one flat KV path string per
# target — the repo/environment relationship is a map key here, not baked
# into a path segment nobody's forced to keep in sync with the actual repo
# name. Mirrors gitops's apps/secrets-sync/values.yaml `targets` shape.

resource "vault_kv_secret_v2" "secrets_sync_github_global" {
  mount = vault_mount.kv.path
  name  = "apps/secrets-sync/github/global"

  data_json_wo         = jsonencode(var.secrets_sync_github.global)
  data_json_wo_version = 1
}

# One object per repo that has repo-wide (no environment) secrets.
resource "vault_kv_secret_v2" "secrets_sync_github_repo" {
  # for_each can't be derived from a sensitive value (Terraform can't tell
  # the *keys* apart from the *values* it's tainting) — nonsensitive() here
  # is scoped to just the repo names, never the actual secret content, which
  # stays properly sensitive-tracked in data_json_wo below.
  for_each = nonsensitive({
    for repo, cfg in var.secrets_sync_github.repos : repo => true
    if length(cfg.secrets) > 0
  })

  mount = vault_mount.kv.path
  name  = "apps/secrets-sync/github/${each.key}"

  data_json_wo         = jsonencode(var.secrets_sync_github.repos[each.key].secrets)
  data_json_wo_version = 1
}

# The only repo+environment target today. Written as a plain resource, not a
# for_each over var.secrets_sync_github.repos.*.environments — there's one
# member, and it needs a special-cased merge (SCW_ACCESS_KEY/SCW_SECRET_KEY
# from infra's own 04-dns/scaleway state, not a hand-copied variable value).
# A generic for_each here would just be a single case with a fake abstraction
# wrapped around it. Revisit if/when a second repo+environment target with no
# remote-state merge shows up.
resource "vault_kv_secret_v2" "secrets_sync_github_infrastructure_scaleway" {
  mount = vault_mount.kv.path
  name  = "apps/secrets-sync/github/infrastructure-scaleway"

  data_json_wo = jsonencode(merge(
    var.secrets_sync_github.repos["infrastructure"].environments["scaleway"],
    {
      SCW_ACCESS_KEY = data.terraform_remote_state.dns_scaleway.outputs.workload_access_key
      SCW_SECRET_KEY = data.terraform_remote_state.dns_scaleway.outputs.workload_secret_key
    }
  ))
  data_json_wo_version = 1
}
