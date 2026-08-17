# The exit-node server's own keypair — one per cluster, not per peer.
# Private key hands off to 05-secrets/openbao/managed (kv/apps/wireguard-exit/
# server-key), which ESO then materializes into the gitops repo's
# services/platform/wireguard-exit Deployment. Public key is non-secret —
# copy it into that same chart's values (it's the identity peers dial, not a
# secret).
resource "wireguard_asymmetric_key" "server" {}

# One keypair per peer in var.peers. Public keys are non-secret — routed
# through 05-secrets/openbao/managed into the gitops repo's peer allowlist.
# Private keys: every entry is a human peer's own credential — see
# outputs.tf's peer_confs for why that never gets written to disk by this
# root itself.
resource "wireguard_asymmetric_key" "peer" {
  for_each = var.peers
}

# Renders a ready-to-import wg-quick config per peer — the whole point of
# minting keys in Terraform instead of by hand with `wg genkey`.
#
# Differs from 04-vpn/wireguard-site-to-site's equivalent data source in
# exactly the two ways that make this an "exit node" instead of a
# point-to-point tunnel:
#   - allowed_ips routes EVERYTHING (0.0.0.0/0, ::/0) into the tunnel, not
#     just the server's own /32 — the whole point being to change the
#     peer's apparent public IP, not reach one specific service.
#   - dns points at a public resolver reachable through the tunnel's own
#     NAT'd egress (gitops repo's services/platform/wireguard-exit/config
#     Deployment does the actual `iptables` MASQUERADE — see that chart's
#     README for why, and 04-vpn/wireguard-site-to-site/README.md for the
#     two dead ends ruled out before landing on hostNetwork+privileged).
#     No split-DNS sidecar here — unlike the site-to-site tunnel, this
#     deployment doesn't need every *.scalepack.fr hostname to resolve
#     specially, so a plain public resolver is enough.
data "wireguard_config_document" "peer" {
  for_each = var.peers

  private_key = wireguard_asymmetric_key.peer[each.key].private_key
  addresses   = [each.value.address]
  dns         = ["1.1.1.1"]

  peer {
    public_key           = wireguard_asymmetric_key.server.public_key
    allowed_ips          = ["0.0.0.0/0", "::/0"]
    endpoint             = var.wg_endpoint
    persistent_keepalive = 25
  }
}
