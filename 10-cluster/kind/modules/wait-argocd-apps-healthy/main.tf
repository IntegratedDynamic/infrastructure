# Factored out of argocd.tf's original wait_platform_apps_healthy/
# wait_bootstrap_healthy resources (infra#84) once the platform-apps DAG grew
# past the original flat "4 domains in parallel, then bootstrap" shape --
# every edge in that DAG needs the identical kubectl-poll-until-healthy
# pattern, just watching a different set of Application names. See
# 10-cluster/scaleway/platform-apps/README.md for why this exists at all
# (ArgoCD has no native way to gate one top-level Application's sync on
# another's health).
resource "kubernetes_job_v1" "wait" {
  metadata {
    name      = var.job_name
    namespace = "argocd"
  }

  spec {
    active_deadline_seconds = var.active_deadline_seconds
    backoff_limit           = 0

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name" = var.job_name
        }
      }

      spec {
        service_account_name = var.service_account_name
        restart_policy       = "Never"

        container {
          name  = "wait"
          image = "alpine/kubectl:1.35.3"

          command = ["sh", "-c", <<-EOT
            set -eu
            apps="${join(" ", var.app_names)}"
            while true; do
              all_healthy=true
              for app in $apps; do
                sync=$(kubectl get application "$app" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
                health=$(kubectl get application "$app" -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || true)
                # health.status alone isn't enough -- a brand-new Application
                # with zero resources synced yet trivially reports Healthy.
                # See argocd.tf's original wait_platform_apps_healthy comment
                # for the confirmed-live incident this guards against.
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

          # Forces a fresh Job (Kubernetes rejects in-place updates to a
          # Job's pod template) whenever whatever this gate watches actually
          # redeploys, and supplies the implicit Terraform dependency on it --
          # see this variable's own description.
          env {
            name  = "REVISION_TRIGGER"
            value = var.revision_trigger
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
    create = var.create_timeout
  }
}
