resource "scaleway_vpc_private_network" "cluster" {}

resource "scaleway_k8s_cluster" "homelab" {
  name    = "homelab"
  version = "1.35"

  auto_upgrade {
    enable                        = true
    maintenance_window_start_hour = 2
    maintenance_window_day        = "any"
  }
  cni                = "cilium"
  type               = "kapsule"
  private_network_id = scaleway_vpc_private_network.cluster.id

  # Alright for homelab, might not be true for production stuff
  delete_additional_resources = true

  tags = ["homelab", "terraform"]
}

resource "scaleway_k8s_pool" "default" {
  cluster_id  = scaleway_k8s_cluster.homelab.id
  name        = "default"
  node_type   = "DEV1-M"
  size        = var.node_count
  min_size    = 0
  max_size    = 3
  autoscaling = false
  autohealing = true

  lifecycle {
    create_before_destroy = true
  }
}

# Without waiting for at least one pool, the cluster status is `pool_required`
# and the DNS entry for the API server is not yet resolvable.
resource "null_resource" "kubeconfig" {
  depends_on = [scaleway_k8s_pool.default]
  triggers = {
    host                   = scaleway_k8s_cluster.homelab.kubeconfig[0].host
    token                  = scaleway_k8s_cluster.homelab.kubeconfig[0].token
    cluster_ca_certificate = scaleway_k8s_cluster.homelab.kubeconfig[0].cluster_ca_certificate
  }
}

resource "local_file" "kubeconfig" {
  depends_on      = [null_resource.kubeconfig]
  content         = scaleway_k8s_cluster.homelab.kubeconfig[0].config_file
  filename        = pathexpand("~/.kube/scaleway-homelab.yaml")
  file_permission = "0600"
}

# Optional local DevX: merge this cluster into ~/.kube/config via the Scaleway
# CLI (instead of juggling the standalone file above). Opt-in via
# install_kubeconfig = true in your *.auto.tfvars. `scw k8s kubeconfig install`
# has no rename flag, so we rename the context cleanly with kubectl afterwards.
resource "null_resource" "install_kubeconfig" {
  count = var.install_kubeconfig ? 1 : 0

  triggers = {
    cluster_id   = scaleway_k8s_cluster.homelab.id
    context_name = var.kubeconfig_context_name
  }

  depends_on = [null_resource.kubeconfig]

  provisioner "local-exec" {
    command = <<-EOT
      scw k8s kubeconfig install ${scaleway_k8s_cluster.homelab.id}
      # Override any pre-existing context with the target name, then rename.
      kubectl config delete-context "${var.kubeconfig_context_name}" 2>/dev/null || true
      kubectl config rename-context "${scaleway_k8s_cluster.homelab.name}-${scaleway_k8s_cluster.homelab.id}" "${var.kubeconfig_context_name}"
    EOT
  }
}

# ── ArgoCD bootstrap (toggle with var.bootstrap_argocd) ─────────────────────

data "infisical_secrets" "this" {
  count        = var.bootstrap_argocd ? 1 : 0
  env_slug     = "staging"
  workspace_id = "7ecb6ed4-058a-46cd-ac9f-7e792469cf0f" // project ID
  folder_path  = "/"
}

resource "helm_release" "argocd" {
  count            = var.bootstrap_argocd ? 1 : 0
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "9.4.17"

  # Fail fast (under the 5m default) if ArgoCD doesn't come up. Transient blips
  # (e.g. quay.io 502s) are absorbed by retrying the apply (see mise scaleway-up).
  timeout = 240

  depends_on = [local_file.kubeconfig]

  set_sensitive {
    name = "configs.secret.argocdServerAdminPassword"
    # ArgoCD expects a bcrypt() hash here. bcrypt() would regenerate on every
    # run, so we store the hash directly in Infisical to avoid spurious diffs.
    value = data.infisical_secrets.this[0].secrets["ArgoCD_admin_encrypted"].value
  }

  values = [<<EOF
configs:
  params:
    server.insecure: true

controller:
  replicas: 1

repoServer:
  replicas: 1
EOF
  ]
}

resource "helm_release" "argocd_apps" {
  count     = var.bootstrap_argocd ? 1 : 0
  name      = "argocd-apps"
  namespace = "argocd"

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.4"

  depends_on = [helm_release.argocd]

  values = [<<EOF
applications:
  bootstrap:
    namespace: argocd
    project: default

    source:
      repoURL: https://github.com/IntegratedDynamic/gitops.git
      targetRevision: ${var.gitops_revision}
      path: bootstrap
      helm:
        parameters:
          - name: env
            value: scaleway
          - name: revision
            value: ${var.gitops_revision}

    destination:
      server: https://kubernetes.default.svc
      namespace: argocd

    syncPolicy:
      automated:
        prune: true
        selfHeal: true
      syncOptions:
        - CreateNamespace=true
EOF
  ]
}
