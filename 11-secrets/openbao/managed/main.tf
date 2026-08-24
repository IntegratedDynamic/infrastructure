# Credentials for the cross-root Scaleway state reads below. Two genuinely
# different execution contexts apply this root, not a speculative one: an
# admin's machine (scw CLI configured, a repo-wide prerequisite already) and
# the Argo Workflows CronWorkflow (gitops repo services/platform/argo-
# workflows) that runs it hourly from inside the cluster, where there's no
# scw CLI and no local config — only SCW_ACCESS_KEY/SCW_SECRET_KEY landed as
# env vars from the apps/argo-workflows/scaleway-state-credentials KV object
# below. Env vars win when set; falling back to `scw config get` keeps the
# admin path exactly as it was.
data "external" "scw_credentials" {
  program = ["sh", "-c", <<-EOT
    jq -n \
      --arg ak "$${SCW_ACCESS_KEY:-$(scw config get access-key)}" \
      --arg sk "$${SCW_SECRET_KEY:-$(scw config get secret-key)}" \
      '{access_key:$ak, secret_key:$sk}'
  EOT
  ]
}

# Shared technical attributes for every cross-root Scaleway state read on
# this page — not "config" in the meaningful sense (they never vary), just
# the Scaleway S3-compatible endpoint mechanics repeated per data source
# otherwise. The actual config — which bucket/key, i.e. which root's state —
# is parametrized via variables.tf + env/, visible there instead of buried
# here.
locals {
  scaleway_state_backend = {
    region                      = "fr-par"
    access_key                  = data.external.scw_credentials.result.access_key
    secret_key                  = data.external.scw_credentials.result.secret_key
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
    use_path_style              = true
    endpoints = {
      s3 = "https://s3.fr-par.scw.cloud"
    }
  }
}

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
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "snapshot"
  bound_service_account_names      = ["openbao-snapshot"]
  bound_service_account_namespaces = ["openbao"]
  token_policies                   = [vault_policy.snapshot.name]
  token_ttl                        = 3600
}

# external-secrets/external-secrets — ESO's ClusterSecretStore
# (gitops repo services/platform/secrets-sync/config/templates/clustersecretstore.yaml).
# Briefly moved to this root as a kubernetes_manifest resource (2026-08-12),
# reverted same day: co-locating it with this role was tidier in the
# abstract, but needed a new `kubernetes` provider on a root that otherwise
# only talks to Vault, plus a cross-root terraform_remote_state read just
# for kubeconfig — real added complexity for a problem (GitOps wave
# ordering looking confusing) that a same-repo move already fixes just as
# well, with none of that. See the gitops repo commit for the actual fix
# and its own tradeoff note (secrets-sync isn't a perfectly clean home
# either — see that file's comment).
resource "vault_kubernetes_auth_backend_role" "external_secrets" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "external-secrets"
  bound_service_account_names      = ["external-secrets"]
  bound_service_account_namespaces = ["external-secrets"]
  token_policies                   = [vault_policy.eso_read.name]
  token_ttl                        = 3600
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

# --- kv/data/apps/*: secret content, not just structure. Uses plain
# data_json, not the write-only data_json_wo/data_json_wo_version pair this
# root used until 2026-08-20 (see infra issue #73): write-only never reads
# secret values back from Vault to diff them, so every content change needed
# a version bump too, by hand, on top of the value change itself — and a
# forgotten bump meant `apply` reported "no changes" while live OpenBao
# silently drifted from state (hit for real after a raft snapshot restore).
# data_json's plaintext-in-state tradeoff buys nothing here to offset that
# risk: every value below already originates from state either way
# (random_password.result, a var, or a terraform_remote_state output), so
# state already holds it in the clear regardless of which attribute writes
# it to Vault. data_json also means drift is now visible on `plan`, not just
# silently accepted.

data "terraform_remote_state" "dns_scaleway" {
  backend = "s3"
  config = merge(local.scaleway_state_backend, {
    bucket = var.dns_scaleway_state_bucket
    key    = var.dns_scaleway_state_key
  })
}

data "terraform_remote_state" "backup_scaleway" {
  backend = "s3"
  config = merge(local.scaleway_state_backend, {
    bucket = var.backup_scaleway_state_bucket
    key    = var.backup_scaleway_state_key
  })
}

# 04-vpn/wireguard-site-to-site's own state — read directly instead of a
# hand-copied local.auto.tfvars value, same as every other cross-root
# credential on this page (dns_scaleway/backup_scaleway above,
# openbao_bootstrap in version.tf). Key is workspace_key_prefix/workspace/key
# from that root's version.tf — left unchanged by both the 04-network ->
# 04-vpn rename and the later wireguard -> wireguard-site-to-site rename
# (CLAUDE.md's "backend keys are decoupled from paths"), so this doesn't
# move if that domain gets renamed again.
data "terraform_remote_state" "wireguard" {
  backend = "s3"
  config = merge(local.scaleway_state_backend, {
    bucket = var.wireguard_state_bucket
    key    = var.wireguard_state_key
  })
}

# 04-vpn/wireguard-exit's own state — the second, unrelated WireGuard
# deployment (consumer-style exit node, not the site-to-site tunnel above).
# Same read-directly-via-remote-state pattern.
data "terraform_remote_state" "wireguard_exit" {
  backend = "s3"
  config = merge(local.scaleway_state_backend, {
    bucket = var.wireguard_exit_state_bucket
    key    = var.wireguard_exit_state_key
  })
}

# --- Arbitrary Dex<->client shared secrets: nothing external constrains
# these values, so Terraform generates and owns them outright — ArgoCD,
# Grafana, and Dex itself all read the *same* kv/apps/dex/credentials object
# below via their own ExternalSecret, so a rotation here propagates to every
# consumer through their existing refresh cycle, no separate copies to sync.
# To rotate: `terraform apply -replace=random_password.<name>` — data_json
# picks up the new value on the next apply, no separate version bump needed.
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

resource "random_password" "argo_workflows_client_secret" {
  length  = 32
  special = false
}

resource "vault_kv_secret_v2" "dex_credentials" {
  mount = vault_mount.kv.path
  name  = "apps/dex/credentials"

  data_json = jsonencode({
    "argocd-client-secret"  = random_password.argocd_client_secret.result
    "envoy-client-secret"   = random_password.envoy_client_secret.result
    "grafana-client-secret" = random_password.grafana_client_secret.result
    "openbao-client-secret" = random_password.openbao_client_secret.result
    "github-client-id"      = var.dex_github_connector["github-client-id"]
    "github-client-secret"  = var.dex_github_connector["github-client-secret"]
    # Not secret (it's Dex's public staticClients.id, gitops repo's
    # services/platform/dex/chart/values-scaleway.yaml), but stored
    # alongside the secret anyway: the argo-workflows Helm chart's
    # server.sso.clientId only accepts a Secret name/key reference, no
    # literal-string option (unlike ArgoCD's own cm.oidc.config, which
    # takes clientID as a literal) -- see argo-workflows/secret's
    # ExternalSecret in the gitops repo for both properties landing
    # together in one Secret.
    "argo-workflows-client-id"     = "argo-workflows"
    "argo-workflows-client-secret" = random_password.argo_workflows_client_secret.result
  })
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

  data_json = jsonencode({
    "admin-user"     = "admin"
    "admin-password" = random_password.grafana_admin_password.result
  })
  # Confirmed live 2026-08-14 that a cluster rebuild restored OpenBao from a
  # raft snapshot holding a stale admin-password — plain data_json now
  # re-diffs and re-writes on the next apply automatically instead of
  # needing a manual version bump (see the write-only postmortem in the
  # top-of-file comment). Still requires a Grafana pod restart afterward:
  # it only applies GF_SECURITY_ADMIN_PASSWORD at admin-user creation
  # (fresh/ephemeral DB), not on every boot against an already-existing
  # admin user.
}

# SCW_ACCESS_KEY/SCW_SECRET_KEY sourced straight from infra's own IAM root
# (01-iam/workload/scaleway) instead of a hand-copied variable — closes the "seed
# pending, no automated push yet" gap that root's own outputs.tf flags.
resource "vault_kv_secret_v2" "external_dns_scaleway_dns_credentials" {
  mount = vault_mount.kv.path
  name  = "apps/external-dns/scaleway-dns-credentials"

  data_json = jsonencode({
    SCW_ACCESS_KEY = data.terraform_remote_state.dns_scaleway.outputs.workload_access_key
    SCW_SECRET_KEY = data.terraform_remote_state.dns_scaleway.outputs.workload_secret_key
  })
}

resource "vault_kv_secret_v2" "secrets_sync_github_eso_private_key" {
  mount = vault_mount.kv.path
  name  = "apps/secrets-sync/github/eso-github-app-private-key"

  data_json = jsonencode(var.secrets_sync_github_eso_private_key)
}

# --- GitHub secrets-sync content, scoped explicitly by org/repo/repo+env
# (see variable "secrets_sync_github") instead of one flat KV path string per
# target — the repo/environment relationship is a map key here, not baked
# into a path segment nobody's forced to keep in sync with the actual repo
# name. Mirrors gitops's apps/secrets-sync/values.yaml `targets` shape.

resource "vault_kv_secret_v2" "secrets_sync_github_global" {
  mount = vault_mount.kv.path
  name  = "apps/secrets-sync/github/global"

  data_json = jsonencode(var.secrets_sync_github.global)
}

# One object per repo that has repo-wide (no environment) secrets.
resource "vault_kv_secret_v2" "secrets_sync_github_repo" {
  # for_each can't be derived from a sensitive value (Terraform can't tell
  # the *keys* apart from the *values* it's tainting) — nonsensitive() here
  # is scoped to just the repo names, never the actual secret content, which
  # stays properly sensitive-tracked in data_json below.
  for_each = nonsensitive({
    for repo, cfg in var.secrets_sync_github.repos : repo => true
    if length(cfg.secrets) > 0
  })

  mount = vault_mount.kv.path
  name  = "apps/secrets-sync/github/${each.key}"

  data_json = jsonencode(var.secrets_sync_github.repos[each.key].secrets)
}

# The only repo+environment target today. Written as a plain resource, not a
# for_each over var.secrets_sync_github.repos.*.environments — there's one
# member, and it needs a special-cased merge (SCW_ACCESS_KEY/SCW_SECRET_KEY
# from infra's own 01-iam/workload/scaleway state, WG_CI_PRIVATE_KEY from
# 04-vpn/wireguard's state — see data.terraform_remote_state.wireguard above).
# A generic for_each here would just be a single case with a fake abstraction
# wrapped around it. Revisit if/when a second repo+environment target with no
# remote-state merge shows up.
resource "vault_kv_secret_v2" "secrets_sync_github_infrastructure_scaleway" {
  mount = vault_mount.kv.path
  name  = "apps/secrets-sync/github/infrastructure-scaleway"

  data_json = jsonencode(merge(
    var.secrets_sync_github.repos["infrastructure"].environments["scaleway"],
    {
      SCW_ACCESS_KEY = data.terraform_remote_state.dns_scaleway.outputs.workload_access_key
      SCW_SECRET_KEY = data.terraform_remote_state.dns_scaleway.outputs.workload_secret_key
      # CI's own WireGuard peer key — brings up the tunnel to OpenBao
      # before CI's own `terraform plan/apply` on
      # 11-secrets/openbao/{bootstrap,managed}. Read straight from
      # 04-vpn/wireguard's state, no local.auto.tfvars copy-paste — same
      # as SCW_ACCESS_KEY/SCW_SECRET_KEY above.
      WG_CI_PRIVATE_KEY = data.terraform_remote_state.wireguard.outputs.peer_private_keys["ci-github-actions"]
    }
  ))
}

# apps/wireguard/server-key — the tunnel server's own key, read back out by
# the gitops repo's services/platform/wireguard/init (ExternalSecret, same
# pattern as every other app's init chart). Its own object, not merged into
# anything else: nothing but that one ExternalSecret ever reads it. Read
# straight from 04-vpn/wireguard's state, no local.auto.tfvars copy-paste.
resource "vault_kv_secret_v2" "wireguard_server_key" {
  mount = vault_mount.kv.path
  name  = "apps/wireguard/server-key"

  data_json = jsonencode({
    "private-key" = data.terraform_remote_state.wireguard.outputs.server_private_key
  })
}

# apps/wireguard/peers — not actually secret (public keys + overlay
# addresses), but routed through the exact same OpenBao -> ESO pipe as
# everything else that crosses from this repo into the gitops repo, rather
# than hardcoded into that repo's values-scaleway.yaml. name -> {publicKey,
# allowedIPs}, matching the shape the gitops repo's services/platform/
# wireguard/config chart expects for its peer allowlist.
resource "vault_kv_secret_v2" "wireguard_peers" {
  mount = vault_mount.kv.path
  name  = "apps/wireguard/peers"

  data_json = jsonencode({
    for name, key in data.terraform_remote_state.wireguard.outputs.peer_public_keys :
    name => {
      publicKey  = key
      allowedIPs = data.terraform_remote_state.wireguard.outputs.peer_addresses[name]
    }
  })
  # Confirmed live 2026-08-10 that a cluster rebuild restored OpenBao from an
  # hourly raft snapshot taken *before* this object was first written —
  # plain data_json now re-diffs and re-writes on the next apply
  # automatically instead of needing a manual version bump (see the
  # write-only postmortem in the top-of-file comment).
}

# apps/wireguard/confs — full rendered wg-quick config per peer (server
# key + AllowedIPs + Endpoint already baked in), sensitive. Deliberately
# NOT synced into the cluster by anything (no ESO ExternalSecret reads
# this) — the only consumer is a human fetching their own config from
# OpenBao's UI/API directly, without needing local Terraform state access
# (recovering onto a new machine, etc.). Same admin-policy trust boundary
# already covers wireguard_server_key/CI's key above — any OpenBao admin
# can already read those, this is no wider a surface than what already
# exists; it just makes retrieval self-service instead of requiring this
# repo's state.
resource "vault_kv_secret_v2" "wireguard_confs" {
  mount = vault_mount.kv.path
  name  = "apps/wireguard/confs"

  data_json = jsonencode(data.terraform_remote_state.wireguard.outputs.peer_confs)
}

# apps/wireguard-exit/{server-key,peers,confs} — same three-object shape as
# apps/wireguard/* above, for the separate exit-node deployment
# (04-vpn/wireguard-exit). Read straight from that root's own state
# (data.terraform_remote_state.wireguard_exit above), no local.auto.tfvars
# copy-paste.
resource "vault_kv_secret_v2" "wireguard_exit_server_key" {
  mount = vault_mount.kv.path
  name  = "apps/wireguard-exit/server-key"

  data_json = jsonencode({
    "private-key" = data.terraform_remote_state.wireguard_exit.outputs.server_private_key
  })
}

resource "vault_kv_secret_v2" "wireguard_exit_peers" {
  mount = vault_mount.kv.path
  name  = "apps/wireguard-exit/peers"

  data_json = jsonencode({
    for name, key in data.terraform_remote_state.wireguard_exit.outputs.peer_public_keys :
    name => {
      publicKey  = key
      allowedIPs = data.terraform_remote_state.wireguard_exit.outputs.peer_addresses[name]
    }
  })
}

# Same "self-service retrieval without needing this repo's state" rationale
# as apps/wireguard/confs above — deliberately not synced into the cluster
# by anything.
resource "vault_kv_secret_v2" "wireguard_exit_confs" {
  mount = vault_mount.kv.path
  name  = "apps/wireguard-exit/confs"

  data_json = jsonencode(data.terraform_remote_state.wireguard_exit.outputs.peer_confs)
}

# apps/velero/scaleway-s3-credentials — Velero's Object Storage credentials
# (gitops repo apps/velero-init, platform/scaleway/velero.yml). A SEPARATE IAM
# key AND bucket from scaleway-s3-credentials (OpenBao's own snapshot agent):
# originally this reused OpenBao's key/bucket, but confirmed live (2026-07-28)
# that OpenBao's snapshot script does a flat `s3cmd ls` on the bucket root for
# its own retention cleanup and chokes on any object/prefix it doesn't own —
# Velero writing into that same bucket broke every subsequent OpenBao
# snapshot job. See 03-storage/scaleway/main.tf's scaleway_object_bucket.velero
# and iam.tf's scaleway_iam_application.velero.
resource "vault_kv_secret_v2" "velero_scaleway_s3_credentials" {
  mount = vault_mount.kv.path
  name  = "apps/velero/scaleway-s3-credentials"

  data_json = jsonencode({
    SCW_ACCESS_KEY = data.terraform_remote_state.backup_scaleway.outputs.velero_workload_access_key
    SCW_SECRET_KEY = data.terraform_remote_state.backup_scaleway.outputs.velero_workload_secret_key
  })
}

# apps/monitoring/thanos-scaleway-s3-credentials — the Prometheus Thanos
# sidecar's Object Storage credentials (gitops repo
# services/platform/monitoring/thanos-secret), reshaped there into Thanos's
# own objstore.yaml format. Separate bucket + IAM key from backup/velero
# (03-storage/scaleway/env/*.tfvars' thanos entry, 1-day retention) — same
# "one bucket, one identity, per consumer, never shared" contract
# (03-storage/README.md) as every other tool bucket in this root.
resource "vault_kv_secret_v2" "thanos_scaleway_s3_credentials" {
  mount = vault_mount.kv.path
  name  = "apps/monitoring/thanos-scaleway-s3-credentials"

  data_json = jsonencode({
    SCW_ACCESS_KEY = data.terraform_remote_state.backup_scaleway.outputs.thanos_workload_access_key
    SCW_SECRET_KEY = data.terraform_remote_state.backup_scaleway.outputs.thanos_workload_secret_key
  })
}

# apps/monitoring/loki-scaleway-s3-credentials — Loki's own Object Storage
# credentials (gitops repo services/platform/monitoring/loki-secret),
# reshaped there into whatever Loki's S3 client expects. Separate bucket +
# IAM key from every other tool bucket (03-storage/scaleway/env/*.tfvars'
# loki entry) — same "one bucket, one identity, per consumer, never shared"
# contract (03-storage/README.md) as thanos above.
resource "vault_kv_secret_v2" "loki_scaleway_s3_credentials" {
  mount = vault_mount.kv.path
  name  = "apps/monitoring/loki-scaleway-s3-credentials"

  data_json = jsonencode({
    SCW_ACCESS_KEY = data.terraform_remote_state.backup_scaleway.outputs.loki_workload_access_key
    SCW_SECRET_KEY = data.terraform_remote_state.backup_scaleway.outputs.loki_workload_secret_key
  })
}

# apps/monitoring/tempo-scaleway-s3-credentials — Tempo's own Object Storage
# credentials (gitops repo services/platform/monitoring/tempo-secret). Same
# contract as loki above: separate bucket + IAM key
# (03-storage/scaleway/env/*.tfvars' tempo entry), never shared.
resource "vault_kv_secret_v2" "tempo_scaleway_s3_credentials" {
  mount = vault_mount.kv.path
  name  = "apps/monitoring/tempo-scaleway-s3-credentials"

  data_json = jsonencode({
    SCW_ACCESS_KEY = data.terraform_remote_state.backup_scaleway.outputs.tempo_workload_access_key
    SCW_SECRET_KEY = data.terraform_remote_state.backup_scaleway.outputs.tempo_workload_secret_key
  })
}

# apps/argo-workflows/scaleway-log-archive-credentials — the Argo Workflows
# controller's own object-storage credentials for archiving container logs
# (artifactRepository.archiveLogs, gitops repo services/platform/argo-
# workflows/chart values-scaleway.yaml). Separate bucket + IAM key from every
# other tool bucket (03-storage/scaleway/env/*.tfvars' argo_workflows_logs
# entry) — same "one bucket, one identity, per consumer, never shared"
# contract (03-storage/README.md) as thanos/loki/tempo above.
resource "vault_kv_secret_v2" "argo_workflows_logs_scaleway_s3_credentials" {
  mount = vault_mount.kv.path
  name  = "apps/argo-workflows/scaleway-log-archive-credentials"

  data_json = jsonencode({
    SCW_ACCESS_KEY = data.terraform_remote_state.backup_scaleway.outputs.argo_workflows_logs_workload_access_key
    SCW_SECRET_KEY = data.terraform_remote_state.backup_scaleway.outputs.argo_workflows_logs_workload_secret_key
  })
}

# apps/argo-workflows/scaleway-state-credentials — read by the gitops repo's
# Argo Workflows CronWorkflow (services/platform/argo-workflows) for both its
# own `terraform init` backend (this root's own bucket, R/W) and the
# data.external.scw_credentials fallback above (the other state buckets this
# file's data.terraform_remote_state blocks read). A dedicated workload
# identity (01-iam/workload/scaleway's "argo-workflows-state"), not one of
# 00-foundation/scaleway's state-bucket identities reused — this credential
# leaves the admin's own machine and lands on the cluster, unlike every
# other cross-root read on this page, so it gets its own identity in
# 01-iam/ like any other in-cluster workload (external-dns, above), not a
# repurposed foundation-layer one.
resource "vault_kv_secret_v2" "argo_workflows_scaleway_state_credentials" {
  mount = vault_mount.kv.path
  name  = "apps/argo-workflows/scaleway-state-credentials"

  data_json = jsonencode({
    SCW_ACCESS_KEY = data.terraform_remote_state.dns_scaleway.outputs.access_keys["argo-workflows-state"]
    SCW_SECRET_KEY = data.terraform_remote_state.dns_scaleway.outputs.secret_keys["argo-workflows-state"]
  })
}

# apps/argo-workflows/openbao-managed-tfvars — a duplicate of the three
# other required, no-default variables this root's own `terraform apply`
# needs (dex_github_connector, secrets_sync_github_eso_private_key,
# secrets_sync_github), so the CronWorkflow's unattended apply is the exact
# same apply an admin would run, not a narrower one. Deliberately a
# duplicate WRITE from the same var, in the same apply, not a read-back of
# the "real" objects above — Terraform has no way to read one resource's
# input back out of another resource's state, so this just writes the same
# admin-supplied value to a second path directly from the var. Keys are
# TF_VAR_*-prefixed and
# values JSON-encoded strings, not nested objects, so the gitops repo's
# shared terraform-apply WorkflowTemplate can just `envFrom: secretRef` this
# whole object straight into the container's environment (only this root's
# CronWorkflow instance references it — the others' extra-secret-name
# points at nothing, see that WorkflowTemplate's optional envFrom) — no
# per-key templating step needed, and Terraform's CLI accepts a
# JSON-encoded string for a map/object-typed variable either way.
resource "vault_kv_secret_v2" "argo_workflows_openbao_managed_tfvars" {
  mount = vault_mount.kv.path
  name  = "apps/argo-workflows/openbao-managed-tfvars"

  data_json = jsonencode({
    TF_VAR_dex_github_connector                = jsonencode(var.dex_github_connector)
    TF_VAR_secrets_sync_github_eso_private_key = jsonencode(var.secrets_sync_github_eso_private_key)
    TF_VAR_secrets_sync_github                 = jsonencode(var.secrets_sync_github)
  })
}
