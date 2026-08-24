# The WireGuard server's own keypair — one per cluster, not per peer. Private
# key hands off to 11-secrets/openbao/managed (kv/apps/wireguard/server-key),
# which ESO then materializes into the gitops repo's
# services/platform/wireguard Deployment. Public key is non-secret — copy it
# into that same chart's values (it's the identity peers dial, not a secret).
resource "wireguard_asymmetric_key" "server" {}

# One keypair per peer in var.peers. Public keys are non-secret — routed
# through 11-secrets/openbao/managed into the gitops repo's peer allowlist.
# Private keys: ci-github-actions hands off to 11-secrets/openbao/managed
# the same way the server key does (see README.md); every other entry is a
# human peer's own credential — see outputs.tf's peer_confs for why that
# never gets written to disk by this root itself.
resource "wireguard_asymmetric_key" "peer" {
  for_each = var.peers
}

# Renders a ready-to-import wg-quick config per peer — the whole point of
# minting keys in Terraform instead of by hand with `wg genkey`.
# ci-github-actions gets one too for consistency, but nothing consumes its
# file: CI only ever needs the raw private key (see
# 11-secrets/openbao/managed's wireguard_ci_private_key), never a config file.
data "wireguard_config_document" "peer" {
  for_each = var.peers

  private_key = wireguard_asymmetric_key.peer[each.key].private_key
  addresses   = [each.value.address]
  # Split DNS: the tunnel server's own `dns` sidecar (gitops repo's
  # services/platform/wireguard-site-to-site/config, dnsInternalZones) answers
  # internal-cluster hostnames (the "svc" / "cluster.local" suffixes — any
  # Service in any namespace, e.g. openbao.openbao.svc.cluster.local) with
  # its own tunnel address while forwarding everything else upstream — so a
  # peer reaches any internal address using its real Service hostname,
  # scoped to exactly this interface's lifetime (nothing to revert when the
  # tunnel goes down, unlike an /etc/hosts edit). Resolving the name only
  # gets a peer to the tunnel pod — that chart's proxy-dynamic sidecar is
  # what actually forwards the traffic on to the real Service, resolved
  # live from the request's own Host header/SNI (infrastructure#81).
  dns = [split("/", var.server_address)[0]]

  peer {
    public_key           = wireguard_asymmetric_key.server.public_key
    allowed_ips          = ["${split("/", var.server_address)[0]}/32"]
    endpoint             = var.wg_endpoint
    persistent_keepalive = 25
  }
}
