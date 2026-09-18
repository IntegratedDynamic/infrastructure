# infra#113: the ONE module both 10-cluster/kind and 10-cluster/scaleway
# call to build their whole platform-apps DAG. See variables.tf's own
# description of var.domains for the full schema -- each root's own
# argocd.tf only needs to declare that map (mostly sourced straight from
# env/*.tfvars) plus whatever handful of genuinely dynamic values (resolved
# revision, root-owned Secret dependencies) it merges on top, and call this
# module once.
#
# Confirmed live (2026-09-17, both via a real `tofu validate` cycle error
# and HashiCorp's own docs on depends_on) that a fully generic, named
# cross-domain DAG (any domain hard/soft-depending on any other by name,
# all within one for_each'd resource) is NOT expressible here, for two
# independent reasons:
#   1. `depends_on` itself only accepts a literal list of direct resource
#      references -- "the list cannot contain arbitrary expressions"
#      (HashiCorp's own docs), so `concat(...)`/ternaries/for-expressions
#      inside it are rejected outright, and `each.key` as an index is
#      rejected too ("a single static variable reference... indexing with
#      constant keys" only).
#   2. Even routed through an ORDINARY argument instead (no such syntax
#      restriction there), OpenTofu's cycle check operates on whole
#      RESOURCE ADDRESSES, not individual instances, whenever a
#      per-instance (`each.value`-derived) condition decides whether a
#      reference exists at all -- so if ANY instance of resource A might
#      reference resource B, and B references ANY instance of A back, the
#      whole A<->B pair is flagged as cyclical, even when the underlying
#      per-instance graph is genuinely acyclic (e.g. "dex-apps" needing
#      "crds-apps" is not a self-loop, but OpenTofu can't see that once A
#      and B reference each other AT ALL).
#
# What's real about this platform's actual DAG (confirmed against every
# existing wait_for/depends_on edge across both roots before this rewrite)
# is that it isn't a deep or wide arbitrary graph -- it reduces to SIX
# individually-named, mutually-independent gates: crds-apps, secrets-apps,
# backups-apps, dex-apps, networking-controllers-apps, grafana-apps. None
# of these six ever needs another one of the six, so they're pulled into
# their OWN resource address (helm_release.gate_domain, terraform_data.
# gate_domain_dep_anchor) entirely separate from every other ("regular")
# domain's (helm_release.domain). A regular domain can safely reference a
# gate's wait Job (kubernetes_job_v1.wait_crds/wait_secrets/.../
# wait_grafana, each a single literally-keyed reference into
# helm_release.gate_domain, never `each.key`) because that Job never
# references back into helm_release.domain -- only into
# helm_release.gate_domain, a genuinely different resource address. This
# keeps the whole graph a real, acyclic DAG while preserving FULL
# parallelism for anything that doesn't need a gate, and ensures no domain
# ever waits on a gate it doesn't actually need (unlike a generic
# topological-level scheme, which would force everything in one level to
# wait for everything in the level below it, whether it needed to or not).

locals {
  domain_specs = {
    for key, d in var.domains : key => {
      source_repo     = d.source == "gitops" ? var.gitops_source_repo : var.infra_source_repo
      source_path     = d.source == "gitops" ? var.gitops_source_path : var.infra_source_path
      target_revision = d.source == "gitops" ? var.gitops_revision : var.infra_revision
      namespace       = d.namespace
      value_files     = d.value_files
      # Every domain gets "revision" automatically -- even a "gitops"-sourced
      # one (bootstrap): it's the gitops repo revision every rendered
      # chart's OWN child Applications should track, independent of which
      # repo this Application's own chart happens to be pulled from.
      parameters = concat([{ name = "revision", value = var.gitops_revision }], d.parameters)
    }
  }

  helm_blocks = {
    for key, spec in local.domain_specs : key => merge(
      length(spec.value_files) > 0 ? { valueFiles = spec.value_files } : {},
      length(spec.parameters) > 0 ? { parameters = spec.parameters } : {},
    )
  }

  # Same Application shape every domain shared verbatim pre-infra#113
  # (finalizers/project/destination/syncPolicy) -- only source/namespace
  # actually vary.
  application_specs = {
    for key, spec in local.domain_specs : key => {
      namespace  = spec.namespace
      finalizers = ["resources-finalizer.argocd.argoproj.io"]
      project    = "default"
      source = merge(
        {
          repoURL        = spec.source_repo
          targetRevision = spec.target_revision
          path           = spec.source_path
        },
        length(local.helm_blocks[key]) > 0 ? { helm = local.helm_blocks[key] } : {},
      )
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = spec.namespace
      }
      syncPolicy = {
        retry = {
          limit = 10
        }
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = ["CreateNamespace=true"]
      }
    }
  }

  # crds-apps sits in its OWN resource address, separate from the other
  # five gates below -- confirmed live (2026-09-17) that
  # networking-controllers-apps (one of the five) has a real dependency on
  # crds-apps (needs_crds = true in every existing tfvars), and lumping it
  # into the SAME for_each'd resource as crds-apps itself would reproduce
  # the exact self-referencing cycle this whole split exists to avoid --
  # wait_crds referencing helm_release.gate_domain["crds-apps"] while
  # ANOTHER instance of that same resource (networking-controllers-apps)
  # referenced wait_crds back. crds-apps has zero incoming needs itself
  # (the most foundational leaf), so it's the one gate genuinely safe to
  # keep singular.
  crds_domain_keys = ["crds-apps"]

  # The five remaining well-known gate domain keys -- hardcoded here, not
  # data-driven, for the same reason crds-apps is split out above. A future
  # seventh gate needs a real edit here, not a tfvars change -- a
  # genuinely rare, structural change, not per-environment config. None of
  # these five may EVER set needs_secrets/needs_backups/needs_dex/
  # needs_networking_controllers/needs_grafana on each other (that would
  # reproduce the same cycle) -- needs_crds is the one exception, safe
  # because crds-apps lives in the separate resource address above.
  gate_domain_keys = [
    "secrets-apps",
    "backups-apps",
    "dex-apps",
    "networking-controllers-apps",
    "grafana-apps",
  ]

  crds_domain     = { for k in local.crds_domain_keys : k => var.domains[k] if contains(keys(var.domains), k) }
  gate_domains    = { for k in local.gate_domain_keys : k => var.domains[k] if contains(keys(var.domains), k) }
  regular_domains = { for k, d in var.domains : k => d if !contains(local.crds_domain_keys, k) && !contains(local.gate_domain_keys, k) }

  has_crds                   = contains(keys(local.crds_domain), "crds-apps")
  has_secrets                = contains(keys(local.gate_domains), "secrets-apps")
  has_backups                = contains(keys(local.gate_domains), "backups-apps")
  has_dex                    = contains(keys(local.gate_domains), "dex-apps")
  has_networking_controllers = contains(keys(local.gate_domains), "networking-controllers-apps")
  has_grafana                = contains(keys(local.gate_domains), "grafana-apps")
}

# ── Shared RBAC for every wait Job below (ex-argocd-wait-rbac) ──────────────
#
# One ServiceAccount/Role/RoleBinding per root, reused by every wait Job it
# creates, instead of minting a fresh one per domain. Scoped to exactly what
# those Jobs need (read-only on Applications in the argocd namespace),
# nothing broader.
resource "kubernetes_service_account" "wait" {
  metadata {
    name      = "wait-platform-apps-healthy"
    namespace = "argocd"
  }
}

resource "kubernetes_role" "wait" {
  metadata {
    name      = "wait-platform-apps-healthy"
    namespace = "argocd"
  }

  rule {
    api_groups = ["argoproj.io"]
    resources  = ["applications"]
    verbs      = ["get", "list"]
  }
}

resource "kubernetes_role_binding" "wait" {
  metadata {
    name      = "wait-platform-apps-healthy"
    namespace = "argocd"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.wait.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.wait.metadata[0].name
    namespace = "argocd"
  }
}

# ── crds-apps' own Application (its own resource address) ──────────────────
#
# The most foundational leaf -- has zero incoming needs of its own, so this
# is the one gate genuinely safe to keep singular. See this file's own
# header comment (locals block) for why it can't share a resource address
# with the other five gates.
resource "terraform_data" "crds_domain_dep_anchor" {
  for_each = local.crds_domain

  input = each.value.depends_on_ids
}

resource "helm_release" "crds_domain" {
  for_each = local.crds_domain

  name      = "argocd-${each.key}"
  namespace = local.application_specs[each.key].namespace

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.4"

  timeout = 1800

  values = [yamlencode({ applications = { (each.key) = local.application_specs[each.key] } })]

  set = [
    {
      name  = "__terraform_dependency_anchor"
      value = terraform_data.crds_domain_dep_anchor[each.key].id
    }
  ]
}

# ── The five remaining gate domains' own Applications (separate resource
#    address from both crds_domain above and helm_release.domain below) ────
#
# May reference kubernetes_job_v1.wait_crds (which only ever points into
# helm_release.crds_domain, a genuinely different resource address) via
# needs_crds -- but never each other's wait Jobs, which WOULD reproduce
# the self-referencing cycle this split exists to avoid.
resource "terraform_data" "gate_domain_dep_anchor" {
  for_each = local.gate_domains

  input = each.value.depends_on_ids
}

resource "helm_release" "gate_domain" {
  for_each = local.gate_domains

  name      = "argocd-${each.key}"
  namespace = local.application_specs[each.key].namespace

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.4"

  timeout = 1800

  values = [yamlencode({ applications = { (each.key) = local.application_specs[each.key] } })]

  # Not real chart values (the argocd-apps chart only ever reads
  # .Values.applications above) -- purely data-flow anchors, since
  # `depends_on` itself forbids both `each.key` as an index and any
  # conditional/concat expression (see this file's own header comment).
  set = concat(
    [
      {
        name  = "__terraform_dependency_anchor"
        value = terraform_data.gate_domain_dep_anchor[each.key].id
      }
    ],
    each.value.needs_crds && local.has_crds ? [{ name = "__terraform_gate_crds", value = kubernetes_job_v1.wait_crds[0].id }] : [],
  )
}

resource "kubernetes_job_v1" "wait_crds" {
  count = local.has_crds ? 1 : 0

  metadata {
    name      = "wait-crds-apps-healthy"
    namespace = "argocd"
  }

  spec {
    active_deadline_seconds = 1800
    backoff_limit           = 0

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name" = "wait-crds-apps-healthy"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.wait.metadata[0].name
        restart_policy       = "Never"

        container {
          name  = "wait"
          image = "alpine/kubectl:1.35.3"

          command = ["sh", "-c", <<-EOT
            set -eu
            app="crds-apps"
            while true; do
              sync=$(kubectl get application "$app" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
              health=$(kubectl get application "$app" -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || true)
              # health.status alone isn't enough -- a brand-new Application
              # with zero resources synced yet trivially reports Healthy.
              if [ "$sync" = "Synced" ] && [ "$health" = "Healthy" ]; then
                echo "Application/$app is Synced and Healthy."
                exit 0
              fi
              echo "Application/$app: sync=$${sync:-<none yet>} health=$${health:-<none yet>}"
              sleep 5
            done
          EOT
          ]

          # Forces a fresh Job whenever crds-apps itself redeploys, and
          # supplies the implicit Terraform dependency on it. Literal key
          # into helm_release.gate_domain -- never `each.key` -- so this
          # never widens into a whole-resource dependency on the "regular"
          # domain pool below.
          env {
            name  = "REVISION_TRIGGER"
            value = helm_release.crds_domain["crds-apps"].metadata.revision
          }
        }
      }
    }
  }

  wait_for_completion = true

  # Must stay above active_deadline_seconds -- this is Terraform's own wait
  # on the Job resource itself, so a shorter value here would make Terraform
  # give up before the Job's own budget even runs out.
  timeouts {
    create = "35m"
  }
}

resource "kubernetes_job_v1" "wait_secrets" {
  count = local.has_secrets ? 1 : 0

  metadata {
    name      = "wait-secrets-apps-healthy"
    namespace = "argocd"
  }

  spec {
    active_deadline_seconds = 1800
    backoff_limit           = 0

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name" = "wait-secrets-apps-healthy"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.wait.metadata[0].name
        restart_policy       = "Never"

        container {
          name  = "wait"
          image = "alpine/kubectl:1.35.3"

          command = ["sh", "-c", <<-EOT
            set -eu
            app="secrets-apps"
            while true; do
              sync=$(kubectl get application "$app" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
              health=$(kubectl get application "$app" -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || true)
              if [ "$sync" = "Synced" ] && [ "$health" = "Healthy" ]; then
                echo "Application/$app is Synced and Healthy."
                exit 0
              fi
              echo "Application/$app: sync=$${sync:-<none yet>} health=$${health:-<none yet>}"
              sleep 5
            done
          EOT
          ]

          env {
            name  = "REVISION_TRIGGER"
            value = helm_release.gate_domain["secrets-apps"].metadata.revision
          }
        }
      }
    }
  }

  wait_for_completion = true

  timeouts {
    create = "35m"
  }
}

resource "kubernetes_job_v1" "wait_backups" {
  count = local.has_backups ? 1 : 0

  metadata {
    name      = "wait-backups-apps-healthy"
    namespace = "argocd"
  }

  spec {
    active_deadline_seconds = 1800
    backoff_limit           = 0

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name" = "wait-backups-apps-healthy"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.wait.metadata[0].name
        restart_policy       = "Never"

        container {
          name  = "wait"
          image = "alpine/kubectl:1.35.3"

          command = ["sh", "-c", <<-EOT
            set -eu
            app="backups-apps"
            while true; do
              sync=$(kubectl get application "$app" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
              health=$(kubectl get application "$app" -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || true)
              if [ "$sync" = "Synced" ] && [ "$health" = "Healthy" ]; then
                echo "Application/$app is Synced and Healthy."
                exit 0
              fi
              echo "Application/$app: sync=$${sync:-<none yet>} health=$${health:-<none yet>}"
              sleep 5
            done
          EOT
          ]

          env {
            name  = "REVISION_TRIGGER"
            value = helm_release.gate_domain["backups-apps"].metadata.revision
          }
        }
      }
    }
  }

  wait_for_completion = true

  timeouts {
    create = "35m"
  }
}

resource "kubernetes_job_v1" "wait_dex" {
  count = local.has_dex ? 1 : 0

  metadata {
    name      = "wait-dex-apps-healthy"
    namespace = "argocd"
  }

  spec {
    active_deadline_seconds = 1800
    backoff_limit           = 0

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name" = "wait-dex-apps-healthy"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.wait.metadata[0].name
        restart_policy       = "Never"

        container {
          name  = "wait"
          image = "alpine/kubectl:1.35.3"

          command = ["sh", "-c", <<-EOT
            set -eu
            app="dex-apps"
            while true; do
              sync=$(kubectl get application "$app" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
              health=$(kubectl get application "$app" -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || true)
              if [ "$sync" = "Synced" ] && [ "$health" = "Healthy" ]; then
                echo "Application/$app is Synced and Healthy."
                exit 0
              fi
              echo "Application/$app: sync=$${sync:-<none yet>} health=$${health:-<none yet>}"
              sleep 5
            done
          EOT
          ]

          env {
            name  = "REVISION_TRIGGER"
            value = helm_release.gate_domain["dex-apps"].metadata.revision
          }
        }
      }
    }
  }

  wait_for_completion = true

  timeouts {
    create = "35m"
  }
}

resource "kubernetes_job_v1" "wait_networking_controllers" {
  count = local.has_networking_controllers ? 1 : 0

  metadata {
    name      = "wait-networking-controllers-apps-healthy"
    namespace = "argocd"
  }

  spec {
    active_deadline_seconds = 1800
    backoff_limit           = 0

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name" = "wait-networking-controllers-apps-healthy"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.wait.metadata[0].name
        restart_policy       = "Never"

        container {
          name  = "wait"
          image = "alpine/kubectl:1.35.3"

          command = ["sh", "-c", <<-EOT
            set -eu
            app="networking-controllers-apps"
            while true; do
              sync=$(kubectl get application "$app" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
              health=$(kubectl get application "$app" -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || true)
              if [ "$sync" = "Synced" ] && [ "$health" = "Healthy" ]; then
                echo "Application/$app is Synced and Healthy."
                exit 0
              fi
              echo "Application/$app: sync=$${sync:-<none yet>} health=$${health:-<none yet>}"
              sleep 5
            done
          EOT
          ]

          env {
            name  = "REVISION_TRIGGER"
            value = helm_release.gate_domain["networking-controllers-apps"].metadata.revision
          }
        }
      }
    }
  }

  wait_for_completion = true

  timeouts {
    create = "35m"
  }
}

resource "kubernetes_job_v1" "wait_grafana" {
  count = local.has_grafana ? 1 : 0

  metadata {
    name      = "wait-grafana-apps-healthy"
    namespace = "argocd"
  }

  spec {
    active_deadline_seconds = 1800
    backoff_limit           = 0

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name" = "wait-grafana-apps-healthy"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.wait.metadata[0].name
        restart_policy       = "Never"

        container {
          name  = "wait"
          image = "alpine/kubectl:1.35.3"

          command = ["sh", "-c", <<-EOT
            set -eu
            app="grafana-apps"
            while true; do
              sync=$(kubectl get application "$app" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
              health=$(kubectl get application "$app" -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || true)
              if [ "$sync" = "Synced" ] && [ "$health" = "Healthy" ]; then
                echo "Application/$app is Synced and Healthy."
                exit 0
              fi
              echo "Application/$app: sync=$${sync:-<none yet>} health=$${health:-<none yet>}"
              sleep 5
            done
          EOT
          ]

          env {
            name  = "REVISION_TRIGGER"
            value = helm_release.gate_domain["grafana-apps"].metadata.revision
          }
        }
      }
    }
  }

  wait_for_completion = true

  timeouts {
    create = "35m"
  }
}

# ── Every other ("regular") domain's own Application ────────────────────────
#
# May reference any of the six gate Jobs above (each a single, literally-
# keyed reference into helm_release.gate_domain, a genuinely different
# resource address -- never a cross-reference back into
# helm_release.domain itself, which is what keeps this acyclic).
resource "terraform_data" "domain_dep_anchor" {
  for_each = local.regular_domains

  input = each.value.depends_on_ids
}

resource "helm_release" "domain" {
  for_each = local.regular_domains

  name      = "argocd-${each.key}"
  namespace = local.application_specs[each.key].namespace

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.4"

  # Applies to both install AND uninstall -- ArgoCD's own
  # resources-finalizer.argocd.argoproj.io makes a Helm uninstall wait for
  # the whole child-Application tree to cascade-delete first, confirmed live
  # to exceed 5 minutes.
  timeout = 1800

  values = [yamlencode({ applications = { (each.key) = local.application_specs[each.key] } })]

  # Not real chart values -- the argocd-apps chart only ever reads
  # .Values.applications (above), so these extra top-level keys are inert
  # to what actually gets rendered. Their only purpose is wiring
  # dependencies through an ORDINARY argument, since `depends_on` forbids
  # both `each.key` as an index and any conditional/concat expression (see
  # this file's own header comment).
  set = concat(
    [
      {
        name  = "__terraform_dependency_anchor"
        value = terraform_data.domain_dep_anchor[each.key].id
      }
    ],
    each.value.needs_crds && local.has_crds ? [{ name = "__terraform_gate_crds", value = kubernetes_job_v1.wait_crds[0].id }] : [],
    each.value.needs_secrets && local.has_secrets ? [{ name = "__terraform_gate_secrets", value = kubernetes_job_v1.wait_secrets[0].id }] : [],
    each.value.needs_backups && local.has_backups ? [{ name = "__terraform_gate_backups", value = kubernetes_job_v1.wait_backups[0].id }] : [],
    each.value.needs_dex && local.has_dex ? [{ name = "__terraform_gate_dex", value = kubernetes_job_v1.wait_dex[0].id }] : [],
    each.value.needs_networking_controllers && local.has_networking_controllers ? [{ name = "__terraform_gate_networking_controllers", value = kubernetes_job_v1.wait_networking_controllers[0].id }] : [],
    each.value.needs_grafana && local.has_grafana ? [{ name = "__terraform_gate_grafana", value = kubernetes_job_v1.wait_grafana[0].id }] : [],
  )
}

# ── The "is EVERY domain actually healthy" check ────────────────────────────
#
# ArgoCD has no native way to express "wait for these independent top-level
# Applications" (sync-wave doesn't cross Application boundaries). Polls
# every domain's own Application directly (both pools), so it subsumes the
# six gates above -- no separate dependency on those Jobs having already
# finished is needed for correctness, only on every Application existing
# (via terraform_data.wait_all_anchor's own reference to every domain's
# helm_release, a leaf nothing else depends on, so no cycle risk regardless
# of it touching every key in both pools).
resource "terraform_data" "wait_all_anchor" {
  count = var.wait_all_domains_healthy ? 1 : 0

  input = concat(
    [for key, d in local.crds_domain : helm_release.crds_domain[key].metadata.revision],
    [for key, d in local.gate_domains : helm_release.gate_domain[key].metadata.revision],
    [for key, d in local.regular_domains : helm_release.domain[key].metadata.revision],
  )
}

resource "kubernetes_job_v1" "wait_all" {
  count = var.wait_all_domains_healthy ? 1 : 0

  metadata {
    name      = "wait-all-domains-healthy"
    namespace = "argocd"
  }

  spec {
    active_deadline_seconds = 1800
    backoff_limit           = 0

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name" = "wait-all-domains-healthy"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.wait.metadata[0].name
        restart_policy       = "Never"

        container {
          name  = "wait"
          image = "alpine/kubectl:1.35.3"

          command = ["sh", "-c", <<-EOT
            set -eu
            apps="${join(" ", keys(var.domains))}"
            while true; do
              all_healthy=true
              for app in $apps; do
                sync=$(kubectl get application "$app" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
                health=$(kubectl get application "$app" -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || true)
                if [ "$sync" != "Synced" ] || [ "$health" != "Healthy" ]; then
                  all_healthy=false
                  echo "Application/$app: sync=$${sync:-<none yet>} health=$${health:-<none yet>}"
                fi
              done
              if [ "$all_healthy" = "true" ]; then
                echo "All watched apps are Synced and Healthy."
                exit 0
              fi
              sleep 5
            done
          EOT
          ]

          env {
            name  = "REVISION_TRIGGER"
            value = join(",", terraform_data.wait_all_anchor[0].input)
          }
        }
      }
    }
  }

  wait_for_completion = true

  timeouts {
    create = "35m"
  }
}
