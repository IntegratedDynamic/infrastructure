# One keypair per identity that needs to reach OpenBao's ClusterIP over the
# tunnel instead of its public gateway route — a human dev machine or the CI
# service identity. `address` is that peer's own /32 on the tunnel's overlay
# subnet (var.server_address) — this map is the single source of truth for
# peer overlay addressing; the gitops repo's services/platform/wireguard
# chart copies it in as a hand-synced value (see README.md's hand-off table).
variable "peers" {
  description = "Peer name -> its own overlay tunnel address. One keypair minted per entry."
  type = map(object({
    address = string
  }))
  default = {
    "nicolas"           = { address = "10.100.0.2/32" }
    "ci-github-actions" = { address = "10.100.0.3/32" }
  }
}

# The tunnel server's own overlay address (CIDR) — must match the gitops
# repo's services/platform/wireguard/config values.yaml `server.address`.
variable "server_address" {
  description = "WireGuard server's own overlay address (CIDR, e.g. 10.100.0.1/24)."
  type        = string
  default     = "10.100.0.1/24"
}

# Where a peer actually dials to reach the tunnel server. A hostname, not a
# raw node IP: Scaleway LBs don't do UDP passthrough (see README.md), so
# this has to be a Kapsule node's public IP directly — which isn't stable
# on its own (changes whenever the server pod reschedules, including this
# cluster's own daily destroy/rebuild). external-dns keeps wg.scalepack.fr
# pointed at whichever node currently hosts the pod (gitops repo's
# services/platform/wireguard/config/templates/service.yaml's
# external-dns.alpha.kubernetes.io/hostname annotation — same mechanism
# every other *.scalepack.fr hostname already uses, no custom script).
# Port must match that chart's values.yaml `server.nodePort` exactly (same
# coupling noted in this infra repo's 10-cluster/scaleway/main.tf).
variable "wg_endpoint" {
  description = "Where peers dial the tunnel server: <hostname>:<NodePort>."
  type        = string
  default     = "wg.scalepack.fr:30820"
}
