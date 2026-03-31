resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "5.51.6"

  values = [<<EOF
server:
  service:
    type: LoadBalancer

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

# resource "helm_release" "metallb" {
#   name       = "metallb"
#   namespace  = "metallb-system"

#   repository = "https://metallb.github.io/metallb"
#   chart      = "metallb"
#   version    = "0.13.12"

#   create_namespace = true
# }

# resource "kubernetes_manifest" "metallb_ip_pool" {
#   manifest = {
#     apiVersion = "metallb.io/v1beta1"
#     kind       = "IPAddressPool"
#     metadata = {
#       name      = "default-pool"
#       namespace = "metallb-system"
#     }
#     spec = {
#       addresses = [
#         "192.168.49.240-192.168.49.250"
#       ]
#     }
#   }

#   depends_on = [helm_release.metallb]
# }

# resource "kubernetes_manifest" "metallb_l2" {
#   manifest = {
#     apiVersion = "metallb.io/v1beta1"
#     kind       = "L2Advertisement"
#     metadata = {
#       name      = "l2"
#       namespace = "metallb-system"
#     }
#     spec = {}
#   }

#   depends_on = [helm_release.metallb]
# }
