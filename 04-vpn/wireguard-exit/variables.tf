# One keypair per device that wants to route its traffic out through this
# cluster's public IP — unlike 04-vpn/wireguard-site-to-site's var.peers,
# there's no "ci-github-actions" entry here: nothing automated consumes an
# exit tunnel. `address` is that peer's own /32 on the tunnel's overlay
# subnet (var.server_address) — this map is the single source of truth for
# peer overlay addressing; the gitops repo's services/platform/wireguard-exit
# chart copies it in as a hand-synced value (see README.md's hand-off table).
variable "peers" {
  description = "Peer name -> its own overlay tunnel address. One keypair minted per entry."
  type = map(object({
    address = string
  }))
  default = {
    "nicolas" = { address = "10.200.0.2/32" }
  }
}

# The tunnel server's own overlay address (CIDR) — separate /24 from
# 04-vpn/wireguard-site-to-site's 10.100.0.0/24 (two independent WireGuard
# interfaces on two independent pods, no shared L3 domain between them, but
# a distinct range keeps the two deployments visually unambiguous). Must
# match the gitops repo's services/platform/wireguard-exit/config values.yaml
# `server.address`.
variable "server_address" {
  description = "WireGuard exit-node server's own overlay address (CIDR, e.g. 10.200.0.1/24)."
  type        = string
  default     = "10.200.0.1/24"
}

# Where a peer actually dials to reach the tunnel server. A hostname, not a
# raw node IP — same reasoning as 04-vpn/wireguard-site-to-site/variables.tf:
# Scaleway LBs don't do UDP passthrough, so this has to be a Kapsule node's
# public IP directly, kept current by external-dns (gitops repo's
# services/platform/wireguard-exit/config/templates/service.yaml's
# external-dns.alpha.kubernetes.io/hostname annotation). Port must match that
# chart's values.yaml `server.nodePort` exactly (same coupling noted in this
# infra repo's 10-cluster/scaleway/main.tf) — 30821, the port after the
# site-to-site tunnel's 30820.
variable "wg_endpoint" {
  description = "Where peers dial the exit-node tunnel server: <hostname>:<NodePort>."
  type        = string
  default     = "wg-exit.scalepack.fr:30821"
}
