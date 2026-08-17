# 04-vpn/wireguard-exit — WireGuard peer keys + client configs for the consumer-style exit node

A second, unrelated WireGuard deployment alongside
`04-vpn/wireguard-site-to-site` — deliberately not an extension of it, a
different scope and a different threat model:

- `wireguard-site-to-site` lets Terraform's `vault` provider reach OpenBao's
  ClusterIP without the public gateway route. It proxies at the application
  layer (a `socat` sidecar) and touches nothing beyond OpenBao.
- `wireguard-exit` is a consumer-style "exit node" (NordVPN-style): a peer
  connects and **all** of its traffic — not just one service — egresses
  through this cluster's public IP, changing the peer's apparent external
  IP. That needs real kernel IP forwarding + NAT, which the site-to-site
  tunnel deliberately avoids.

## Connect

Requires `wireguard-tools` (`brew install wireguard-tools` on macOS) — same
note as the site-to-site tunnel's README: the official WireGuard.app GUI has
known DNS resolution issues with its sandboxed NetworkExtension that
`wg-quick` doesn't have; use the CLI.

```bash
mise run vpn-exit-generate   # once, and again any time your config needs refreshing
mise run vpn-exit-up         # your own tunnel — add a peer name if you're not "nicolas"
mise run vpn-exit-down       # when you're done
```

**Once up, this routes ALL of your traffic through the cluster** — unlike
the site-to-site tunnel, there's no narrower `AllowedIPs`. Expect your
apparent public IP (`curl ifconfig.me`) to change, and DNS to resolve via
the tunnel's own upstream resolver, not your local network's.

`vpn-exit-generate` writes a ready-to-use `wg-quick` config per peer to
`generated/` (gitignored, `0600`) — `vpn-exit-up`/`vpn-exit-down` just point
`wg-quick` at the right one, same reasoning as the site-to-site tunnel's
README.

Adding a new peer: add an entry to `var.peers` (both `variables.tf`'s
default and `env/04-network-wireguard-exit.tfvars`), `mise run
vpn-exit-generate`, then do the manual hand-offs below for just that new
entry.

## Manual hand-offs — hardcoded cross-repo coupling to track

Same "two systems kept in sync by convention, not automation" pattern as
`04-vpn/wireguard-site-to-site/README.md` — nothing here talks to the
gitops repo or to OpenBao directly.

| Value | From | To | Why manual |
|---|---|---|---|
| `server_public_key`, `peer_public_keys` (not secret) | this root's outputs | gitops `services/platform/wireguard-exit/config/values-scaleway.yaml` | no cross-repo automation exists anywhere in this setup |
| `server_private_key` (sensitive) | this root's output | `05-secrets/openbao/managed`'s exit-node key resource → `kv/apps/wireguard-exit/server-key` → gitops `wireguard-exit-secret`'s ExternalSecret | same |
| every peer's private key | this root's output | that peer's own machine only (`generated/<name>.conf`) | never touches OpenBao or git, by design |
| NodePort `30821` | gitops `services/platform/wireguard-exit/config/values.yaml` `server.nodePort` | infra `10-cluster/scaleway/main.tf`'s security group rule, **and** this root's `wg_endpoint` port | two independent files, must match exactly — one port after the site-to-site tunnel's `30820` |
| egress interface `ens2` | gitops `services/platform/wireguard-exit/config/values-scaleway.yaml` `egressInterface` | this root's README (below) | Kapsule node-image specific; confirmed live via `kubectl exec` into an existing Cilium pod (`ip route get 1.1.1.1` → `dev ens2`) — re-verify if Scaleway ever changes the node image's interface naming |

## Why hostNetwork + privileged, not the site-to-site tunnel's app-layer proxy

`wireguard-site-to-site` proxies at the application layer specifically to
avoid kernel routing: an earlier attempt there routed/NAT'd to OpenBao's
ClusterIP via `net.ipv4.ip_forward` + `iptables` MASQUERADE, set through
Kubernetes' `securityContext.sysctls` — a dead end, since Kapsule's kubelet
doesn't allowlist that sysctl and Scaleway's `kubelet_args` API refuses to
widen the allowlist for this cluster's k8s version at all (see
`04-vpn/wireguard-site-to-site/README.md`'s "Why the tunnel doesn't route to
OpenBao's ClusterIP directly").

An exit node has no way around this: the whole point is routing a peer's
*arbitrary* traffic, not proxying to one known destination, so application-
layer proxying doesn't apply. Confirmed live on this cluster instead:
`hostNetwork: true` + `securityContext.privileged: true` on the gitops
chart's pod (`services/platform/wireguard-exit/config`), with
`net.ipv4.ip_forward=1` and the `iptables` MASQUERADE rule run directly by
the container's own startup (WireGuard's `PostUp`, executed automatically by
`wg-quick`) — this never goes through the Kubernetes sysctls admission path
at all, since it's a plain syscall from a process that already has
`CAP_SYS_ADMIN` (granted by `privileged: true`) writing straight to
`/proc/sys/net/ipv4/ip_forward` in the host's own network namespace (shared
via `hostNetwork`).

Accepted as viable on this specific cluster: no restrictive PodSecurity
admission, no Kyverno/Gatekeeper installed, and Cilium itself already runs
`hostNetwork: true` + privileged — this isn't a new risk class for the
cluster, just a second workload using a pattern already present.

## Why exposure is a NodePort, not the shared Gateway

Same reasoning as `04-vpn/wireguard-site-to-site/README.md`'s equivalent
section: Scaleway's cloud-controller-manager silently drops any non-TCP
`Service` port when building its LoadBalancer, so a `UDPRoute` on the shared
Gateway's LB is never reachable. Exposed instead as a `NodePort` on a
Kapsule node's public IP, hardened the same way: `externalTrafficPolicy:
Local` + an explicit least-privilege `NetworkPolicy`, plus the same
`scaleway_instance_security_group` (`10-cluster/scaleway/main.tf`) the
site-to-site tunnel already relies on, extended with one more inbound rule
(`UDP/30821`).

Kept as a `NodePort` Service even though the pod itself sits on
`hostNetwork` (so its listener is already bound directly to the host) —
purely so `external-dns`'s `service` source keeps tracking which node
currently hosts the single replica, the same mechanism `wg.scalepack.fr`
already relies on. This NodePort-DNAT-to-a-hostNetwork-pod interaction
hasn't been exercised on this cluster before (the site-to-site tunnel's pod
is *not* on `hostNetwork`) — first thing to verify once deployed.

## What it creates

- `wireguard_asymmetric_key.server` — the exit-node server's own keypair.
- `wireguard_asymmetric_key.peer` (`for_each = var.peers`) — one keypair
  per peer.
- `data.wireguard_config_document.peer` — renders each peer's full
  `wg-quick` config (their own key, the server's public key, full-tunnel
  `AllowedIPs`, `wg_endpoint`, a public DNS resolver).

Providers: [`OJFord/wireguard`](https://registry.terraform.io/providers/OJFord/wireguard)
(local key generation + config rendering, no credentials, no API calls).
