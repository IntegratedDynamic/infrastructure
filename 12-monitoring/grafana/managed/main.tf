# mcp-claude-code — the Grafana MCP server's (github.com/grafana/mcp-grafana)
# own service account, used by Claude Code locally to query dashboards,
# datasources, and alerts. role = "Editor" per that project's own
# recommendation: enough for its typical toolset without full Admin.
resource "grafana_service_account" "mcp_claude_code" {
  name = "mcp-claude-code"
  role = "Editor"
}

resource "grafana_service_account_token" "mcp_claude_code" {
  name               = "mcp-claude-code"
  service_account_id = grafana_service_account.mcp_claude_code.id
  seconds_to_live    = var.mcp_service_account_token_ttl_days * 24 * 3600
}

# The Prometheus datasource + the ~27 default dashboards below used to come
# free from kube-prometheus-stack's own parent chart (templates/grafana/
# configmaps-datasources.yaml + templates/grafana/dashboards-1.14/*.yaml) —
# lost when Grafana was split out into its own chart/Application
# (gitops repo's services/platform/monitoring/grafana-chart, 2026-08-14, see
# that split's own rationale: the grafana-restore-* PreSync hook needs a
# wave after Velero, which the combined kube-prometheus-stack chart's own
# wave couldn't give it). Recreated here instead of via a ConfigMap
# sidecar, consistent with this root's whole purpose ("Grafana's actual
# declarative configuration" per 12-monitoring/grafana/README.md).
#
# URL is the in-cluster Service Prometheus still gets from
# services/platform/monitoring/chart (unaffected by the split) — verified
# via `helm template` against that chart's actual release name, not
# assumed. is_default = true is sufficient for the dashboards below to
# resolve correctly: they reference a Grafana-native `$datasource` template
# variable, not a hardcoded datasource UID (confirmed by inspecting a
# rendered dashboard JSON), so Grafana auto-selects whichever datasource is
# marked default.
#
# uid pinned to a stable literal, not left for Grafana to auto-generate.
# infra#82 mode 2 (first hit live 2026-08-23): after a Velero PVC restore,
# Grafana served "Prometheus" under a different random uid than the one in
# state, so `apply` tried a plain POST /datasources for a name that already
# existed and wedged on a 409 (the provider has no adopt-if-present
# behavior). The Argo Workflows preflight script that used to work around
# this with `state rm` + `import` is gone (issue #101) -- pinning the uid
# removes the drift class instead: every snapshot taken after this change
# carries the datasource under uid "prometheus", so any restore yields the
# uid state already expects. `uid` is ForceNew on grafana_data_source, so
# the very first apply of this change replaces the auto-uid datasource
# once (harmless: dashboards resolve via the `$datasource` template var,
# not a hardcoded uid -- see grafana_dashboard.defaults below). Residual,
# documented in README.md: a restore from a snapshot OLDER than this change
# still needs a one-off `tofu state rm grafana_data_source.<name>` + apply.
resource "grafana_data_source" "prometheus" {
  type        = "prometheus"
  name        = "Prometheus"
  uid         = "prometheus"
  url         = "http://kube-prometheus-stack-prometheus.monitoring.svc:9090"
  access_mode = "proxy"
  is_default  = true
}

# Loki + Tempo — same pattern as prometheus above, added alongside
# gitops#29 (Loki/Tempo/Alloy/OTel Collector). URLs are a BEST-EFFORT GUESS
# at the Service names gitops#29's charts will create — assumed release
# name == chart name (loki/tempo), matching this cluster's existing
# convention (see the prometheus datasource's own comment on how
# `kube-prometheus-stack-prometheus` was derived) — and Loki's optional
# nginx `gateway` disabled (querying the SingleBinary pod's own :3100
# directly; one less pod on a pool that's already tight, per argocd.tf's
# resource-sizing comment). NOT yet verified against a live chart the way
# the prometheus URL was — double-check both URLs once gitops#29 actually
# lands, same as that comment warns for its own case.
resource "grafana_data_source" "loki" {
  type        = "loki"
  name        = "Loki"
  uid         = "loki" # pinned -- see grafana_data_source.prometheus's comment (infra#82 mode 2)
  url         = "http://loki.monitoring.svc:3100"
  access_mode = "proxy"

  # grafana_data_source_config.loki (below) manages json_data_encoded
  # out-of-band from this resource's own plan — without ignoring it here,
  # every subsequent plan would show spurious drift fighting that resource
  # (documented gotcha for this exact circular-reference case:
  # registry.terraform.io/grafana/grafana's data_source_config docs).
  lifecycle {
    ignore_changes = [json_data_encoded, http_headers]
  }
}

resource "grafana_data_source" "tempo" {
  type        = "tempo"
  name        = "Tempo"
  uid         = "tempo" # pinned -- see grafana_data_source.prometheus's comment (infra#82 mode 2)
  url         = "http://tempo.monitoring.svc:3200"
  access_mode = "proxy"

  lifecycle {
    ignore_changes = [json_data_encoded, http_headers]
  }
}

# Loki -> Tempo (click a trace ID in a log line, jump to that trace) and
# Tempo -> Loki/Prometheus (click a trace, jump to its logs/service
# metrics) correlation. Split into grafana_data_source_config instead of
# setting json_data_encoded directly on the two resources above because
# they reference each other's uid — a genuine circular dependency Terraform
# can only resolve by decoupling the datasource's existence from its
# cross-referencing config (same shape as the provider's own documented
# example for this exact Loki<->Tempo pairing).
#
# derivedFields' matcherRegex is Grafana's own generic doc-example pattern
# for a "trace_id"/"traceID" field in a log line — not verified against any
# app's actual log format yet, since nothing emits trace IDs into logs
# until gitops#29's OTel Collector + an instrumented app exist. Harmless if
# it never matches (derived fields are opt-in navigation, not required for
# anything else to work); revisit the regex once a real instrumented app's
# log shape is known.
resource "grafana_data_source_config" "loki" {
  uid = grafana_data_source.loki.uid

  json_data_encoded = jsonencode({
    derivedFields = [
      {
        datasourceUid = grafana_data_source.tempo.uid
        matcherRegex  = "[tT]race_?[iI][dD]\"?[:=]\"?(\\w+)"
        matcherType   = "regex"
        name          = "traceID"
        url           = "$${__value.raw}"
      }
    ]
  })
}

# Deliberately minimal: no customQuery (let Tempo build the Loki query from
# its own default tag matching rather than a hand-written LogQL query
# assuming label names we haven't settled on) and no tracesToMetrics/
# serviceMap yet — serviceMap in particular needs a spanmetrics connector
# in the OTel Collector to exist first (not in gitops#29's scope), so
# wiring it now would point at a Prometheus metric that doesn't exist.
resource "grafana_data_source_config" "tempo" {
  uid = grafana_data_source.tempo.uid

  json_data_encoded = jsonencode({
    tracesToLogsV2 = {
      datasourceUid   = grafana_data_source.loki.uid
      filterBySpanID  = false
      filterByTraceID = false
    }
  })
}

# dashboards/*.json are the exact same dashboards kube-prometheus-stack
# 86.1.0 would otherwise auto-deploy — extracted (not hand-written) by
# rendering services/platform/monitoring/chart with
# grafana.forceDeployDashboards=true and pulling each ConfigMap's
# data.<name>.json value verbatim, so this is a lift of what was already
# running, not a rewrite. Each file's first key is a "//" comment (JSON has
# no real comment syntax — this is the same convention package.json/
# tasks.json/AWS SAM use) giving the exact, version-pinned upstream URL
# that JSON came from, read straight out of the vendored chart's own
# template header comments ("Generated from '<name>' from <url>") — most
# point at kube-prometheus's grafana-dashboardDefinitions.yaml pinned to
# the commit that chart version vendors; etcd/k8s-coredns instead point
# at prometheus-community/helm-charts' own kube-prometheus-stack-86.1.0
# tag, since those two are sourced from inside that repo, not fetched from
# a further upstream. All three URL shapes verified live (`curl -I` / `git
# ls-remote --tags`) to actually resolve. To refresh these dashboards for a
# newer chart version: bump the version everywhere it's pinned (this
# root's own comment, gitops repo's grafana-chart/Chart.yaml,
# services/platform/monitoring/chart/Chart.yaml), re-render with
# grafana.forceDeployDashboards=true, and regenerate this directory the
# same way — don't hand-edit individual dashboard JSON.
#
# Not yet independently verified live: whether Grafana's dashboard model
# silently drops an unrecognized top-level "//" key (expected — dashboards
# routinely carry tool-added extras like __inputs/__requires from
# grafana.com exports) or echoes it back, which would make config_json
# diff against itself on every plan. If a `terraform plan` ever shows
# perpetual drift here, that's the first thing to check.
#
# No folder argument — lands in Grafana's default/General folder, matching
# the sidecar-provisioned behavior this replaces.
# overwrite = true: safe to re-apply over a dashboard a human tweaked via
# the UI (Terraform's version wins), same tradeoff the rest of this
# cluster already makes for anything IaC-owned.
resource "grafana_dashboard" "defaults" {
  for_each = fileset(path.module, "dashboards/*.json")

  config_json = file("${path.module}/${each.value}")
  overwrite   = true
}
