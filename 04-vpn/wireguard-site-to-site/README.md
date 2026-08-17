# 04-vpn/wireguard-site-to-site — WireGuard peer keys + client configs for the OpenBao tunnel

Renamed from `04-vpn/wireguard` once a second, unrelated WireGuard
deployment (`04-vpn/wireguard-exit` — a consumer-style exit node, all of a
peer's traffic routed through the cluster, not just OpenBao) showed up
alongside it. Pure directory rename — `workspace_key_prefix` and this root's
`env/04-network-wireguard.tfvars` filename/workspace name are untouched, so
it needed zero state migration (see root `CLAUDE.md`'s "Backend keys are
decoupled from paths").

## Connect

Requires `wireguard-tools` (`brew install wireguard-tools` on macOS) — the
official WireGuard.app GUI has known DNS resolution issues with its
sandboxed NetworkExtension that `wg-quick` doesn't have; use the CLI.

```bash
mise run vpn-generate   # once, and again any time your config needs refreshing
mise run vpn-up         # your own tunnel — add a peer name if you're not "nicolas"
mise run vpn-down       # when you're done
```

`vpn-generate` writes a ready-to-use `wg-quick` config per peer to
`generated/` (gitignored, `0600`) — `vpn-up`/`vpn-down` just point
`wg-quick` at the right one, since its own "bare name" lookup only finds
configs already living in its own config directory, not ones Terraform
generates here.

Adding a new peer: add an entry to `var.peers` (both `variables.tf`'s
default and `env/04-network-wireguard.tfvars`), `mise run vpn-generate`,
then do the manual hand-offs below for just that new entry.

## Manual hand-offs — hardcoded cross-repo coupling to track

Nothing here talks to the gitops repo or to OpenBao directly. Every row is
a human copying a `terraform output` value somewhere else — same "two
systems kept in sync by convention, not automation" pattern as
`05-secrets/openbao/managed`'s `secrets_sync_github` vs. the gitops repo's
`apps/secrets-sync/values.yaml`. Accepted for now; each row is a spot that
silently breaks if only one side changes.

| Value | From | To | Why manual |
|---|---|---|---|
| `server_public_key`, `peer_public_keys` (not secret) | this root's outputs | gitops `services/platform/wireguard-site-to-site/config/values-scaleway.yaml` | no cross-repo automation exists anywhere in this setup |
| `server_private_key` (sensitive) | this root's output | `05-secrets/openbao/managed`'s `wireguard_server_private_key` (`local.auto.tfvars`) → `kv/apps/wireguard/server-key` → gitops `wireguard-init`'s ExternalSecret | same |
| `peer_private_keys["ci-github-actions"]` (sensitive) | this root's output | `05-secrets/openbao/managed`'s `wireguard_ci_private_key` → merged into the *existing* `kv/apps/secrets-sync/github/infrastructure-scaleway` object (not its own KV path — nothing reads that) → secrets-sync → GitHub Actions secret | same; direction is OpenBao→GitHub via in-cluster ESO, so CI never needs the tunnel to fetch its own tunnel key |
| every other peer's private key | this root's output | that peer's own machine only (`generated/<name>.conf`) | never touches OpenBao or git, by design |
| NodePort `30820` | gitops `services/platform/wireguard-site-to-site/config/values.yaml` `server.nodePort` | infra `10-cluster/scaleway/main.tf`'s security group rule, **and** this root's `wg_endpoint` port | two independent files, must match exactly |

## Why this exists

`05-secrets/openbao/{bootstrap,managed}`'s `vault` provider needs a network
path to OpenBao's API — this root exists so that path can be a self-hosted
tunnel instead of the public gateway route (`openbao.scalepack.fr`), which
stays public only for a separate, legitimate reason: human OIDC/UI login
(gitops repo's `services/platform/openbao/config`), untouched by this
domain. No third-party control plane (Tailscale evaluated, ruled out) —
just `wg`, terminated by a small server workload in the gitops repo
(`services/platform/wireguard-site-to-site`).

**End-to-end validated live 2026-08-09**: a peer handshakes and reaches
OpenBao's `/v1/sys/health` through the full chain (tunnel → gitops's
`proxy-openbao` sidecar → OpenBao's Service).

## Why exposure is a NodePort, not the shared Gateway

Scaleway's cloud-controller-manager silently drops any non-TCP `Service`
port when building its LoadBalancer (`loadbalancers.go`:
`if port.Protocol != v1.ProtocolTCP { skip }`) — a `UDPRoute` on the shared
Gateway's LB was never reachable no matter how correctly Envoy Gateway
itself was configured; confirmed live, zero datagrams ever arrived despite
every Gateway API resource reporting `Accepted`/`Programmed`.

Exposed instead as a `NodePort` directly on a Kapsule node's public IP — a
genuinely new entry point, hardened accordingly: `externalTrafficPolicy:
Local` + an explicit least-privilege `NetworkPolicy` (gitops repo's
`services/platform/wireguard-site-to-site/config`), plus a dedicated
`scaleway_instance_security_group` replacing Scaleway's auto-managed
default one, which ships with zero inbound rules and would otherwise block
this (and everything else) at the instance level regardless of any
Kubernetes-side config (`10-cluster/scaleway/main.tf`).

A raw node IP isn't stable — it changes on every reschedule, including
this cluster's own daily destroy/rebuild. Fixed via `external-dns`, not a
custom script: its `service` source has first-class support for exactly
`NodePort` + `externalTrafficPolicy: Local` (resolves the ExternalIP of
whichever node currently has a live pod), so `wg.scalepack.fr` — the
`wg_endpoint` default — stays correct on its own, the same mechanism every
other `*.scalepack.fr` hostname in this cluster already relies on. See
that chart's `templates/service.yaml` annotation.

## Why the tunnel doesn't route to OpenBao's ClusterIP directly

An earlier design routed/NAT'd traffic to OpenBao's `ClusterIP` at the
kernel level (`net.ipv4.ip_forward` + `iptables` MASQUERADE) — a dead end:
Kapsule's kubelet doesn't allowlist that sysctl, and Scaleway's
`kubelet_args` API refuses to widen the allowlist for this cluster's k8s
version at all. Even where available, that's a cluster-wide relaxation for
one workload's benefit — worth avoiding regardless.

The gitops chart instead terminates the tunnel and proxies to OpenBao at
the application layer (a `socat` sidecar resolving
`openbao.openbao.svc.cluster.local` via ordinary in-cluster DNS) — no
kernel routing, no sysctls, no dependency on OpenBao's `ClusterIP` being
stable across a cluster rebuild.

## Why its own domain, and why it's temporary

Identities normally live in `01-iam/`, secrets in `05-secrets/`. Neither
fits a WireGuard peer well: it isn't a cloud-provider IAM identity, and a
keypair's public half isn't a secret at all. Placeholder domain of its
own, explicitly temporary — expect this to fold into `01-iam/workload/` (or
be replaced entirely) once the shape of "what kind of thing is a WireGuard
peer" is clearer.

## What it creates

- `wireguard_asymmetric_key.server` — the tunnel server's own keypair.
- `wireguard_asymmetric_key.peer` (`for_each = var.peers`) — one keypair
  per peer.
- `data.wireguard_config_document.peer` — renders each peer's full
  `wg-quick` config (their own key, the server's public key, `AllowedIPs`,
  `wg_endpoint`).
- `local_sensitive_file.peer_conf` — writes that config to `generated/`.

Providers: [`OJFord/wireguard`](https://registry.terraform.io/providers/OJFord/wireguard)
(local key generation + config rendering, no credentials, no API calls) and
`hashicorp/local` (writes the file).
