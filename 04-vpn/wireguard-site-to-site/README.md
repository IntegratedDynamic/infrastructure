# 04-vpn/wireguard-site-to-site — WireGuard peer keys + client configs for the OpenBao tunnel

Renamed from `04-vpn/wireguard` once a second, unrelated WireGuard
deployment (`04-vpn/wireguard-exit` — a consumer-style exit node, all of a
peer's traffic routed through the cluster, not just OpenBao) showed up
alongside it. That directory rename was a pure `git mv` — `workspace_key_prefix`
and the tfvars filename/workspace name were left untouched at the time, so it
needed zero state migration.

`workspace_key_prefix` and the workspace name (`env/04-vpn-wireguard-site-to-site-dev.tfvars`)
now mirror this root's own path (2026-08-24 workspace-naming refacto — this
one *did* need a real state migration, since the prefix/workspace were
changing; see root `CLAUDE.md`'s "Backend keys are decoupled from paths").

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
default and `env/04-vpn-wireguard-site-to-site-dev.tfvars`), `mise run vpn-generate`,
then do the manual hand-offs below for just that new entry.

## Manual hand-offs — hardcoded cross-repo coupling to track

Nothing here talks to the gitops repo or to OpenBao directly. Every row is
a human copying a `terraform output` value somewhere else — same "two
systems kept in sync by convention, not automation" pattern as
`11-secrets/openbao/managed`'s `secrets_sync_github` vs. the gitops repo's
`apps/secrets-sync/values.yaml`. Accepted for now; each row is a spot that
silently breaks if only one side changes.

| Value | From | To | Why manual |
|---|---|---|---|
| `server_public_key`, `peer_public_keys` (not secret) | this root's outputs | gitops `services/platform/wireguard-site-to-site/config/values-scaleway.yaml` | no cross-repo automation exists anywhere in this setup |
| `server_private_key` (sensitive) | this root's output | `11-secrets/openbao/managed`'s `wireguard_server_private_key` (`local.auto.tfvars`) → `kv/apps/wireguard/server-key` → gitops `wireguard-init`'s ExternalSecret | same |
| `peer_private_keys["ci-github-actions"]` (sensitive) | this root's output | `11-secrets/openbao/managed`'s `wireguard_ci_private_key` → merged into the *existing* `kv/apps/secrets-sync/github/infrastructure-scaleway` object (not its own KV path — nothing reads that) → secrets-sync → GitHub Actions secret | same; direction is OpenBao→GitHub via in-cluster ESO, so CI never needs the tunnel to fetch its own tunnel key |
| every other peer's private key | this root's output | that peer's own machine only (`generated/<name>.conf`) | never touches OpenBao or git, by design |
| NodePort `30820` | gitops `services/platform/wireguard-site-to-site/config/values.yaml` `server.nodePort` | infra `10-cluster/scaleway/main.tf`'s security group rule, **and** this root's `wg_endpoint` port | two independent files, must match exactly |

## Why this exists

`11-secrets/openbao/{bootstrap,managed}`'s `vault` provider needs a network
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

## Why the tunnel doesn't route to internal ClusterIPs directly

An earlier design routed/NAT'd traffic to a target's `ClusterIP` at the
kernel level (`net.ipv4.ip_forward` + `iptables` MASQUERADE) — a dead end:
Kapsule's kubelet doesn't allowlist that sysctl, and Scaleway's
`kubelet_args` API refuses to widen the allowlist for this cluster's k8s
version at all. Even where available, that's a cluster-wide relaxation for
one workload's benefit — worth avoiding regardless.

The gitops chart instead terminates the tunnel and proxies at the
application layer: no kernel routing, no sysctls, no dependency on any
`ClusterIP` being stable across a cluster rebuild. A first pass at this
(infrastructure#81's initial PR, 2026-08-24) used one `socat` sidecar per
named target (`proxyTargets: {name: {port, target}}`) — simple, but meant
listing every internal Service by hand, one PR per addition. Replaced the
same day with `proxy-dynamic` (gitops repo's `services/platform/
wireguard-site-to-site/config`, `dynamicProxy`): a single `nginx` sidecar
that resolves the *actual* backend live from what the peer's own request
names — the plain-HTTP request's `Host` header (`dynamicProxy.httpPorts`)
or the TLS ClientHello's SNI (`dynamicProxy.tlsPorts`, passthrough via
`ssl_preread`, no certificate needed) — against this cluster's own CoreDNS,
instead of a hardcoded target. Any internal Service on an already-listened
port is reachable the moment DNS resolves its name (see "Internal cluster
DNS" below); nothing to add to the gitops chart when a new one shows up.

A TCP listener still has to be bound per **port** ahead of time (a socket
can't cover every port at once) — that's the one thing not fully dynamic.
`dynamicProxy.httpPorts` covers OpenBao's plain-HTTP API (`8200`) and
Grafana (`80`) today; add a port there (not a target) the day some other
internal service needs one neither already covers.

**Verified live 2026-08-24** (a debug pod running the exact rendered
`nginx.conf`, `nginx -t` plus a real request): `curl` with `Host:
openbao.openbao.svc.cluster.local:8200` returns OpenBao's real
`/v1/sys/health`, and `Host: grafana.monitoring.svc.cluster.local` against
port `80` returns Grafana's normal 302 — both driven purely by the Host
header, no target hardcoded anywhere in the proxy.

## Internal cluster DNS

The tunnel server's `dns` sidecar (gitops repo's
`services/platform/wireguard-site-to-site/config`, `dnsInternalZones`)
answers any hostname under the `svc` or `cluster.local` suffixes with its
own tunnel address, instead of one hostname hardcoded per target — so a
peer resolves any internal Service name generically (both the full
`<name>.<namespace>.svc.cluster.local` form and the short
`<name>.<namespace>.svc` form Argo Workflows already uses in-cluster).
`*.scalepack.fr` split-DNS and the `proxy-gateway` sidecar it fed (SNI
passthrough to Envoy Gateway, for OIDC-gated web UIs) were removed
2026-08-24 (infrastructure#81) — this domain is for machine credentials
reaching an internal API, not human OIDC/UI login, which stays on the
public route untouched.

`11-secrets/openbao/{bootstrap,managed}` default to
`http://openbao.openbao.svc:8200/` and `12-monitoring/grafana/
{bootstrap,managed}` to `http://grafana.monitoring.svc:80/` — both reach
their target through `proxy-dynamic` above once the tunnel is up (see each
root's own `version.tf`/`variables.tf`).

## Why its own domain, and why it's temporary

Identities normally live in `01-iam/`, secrets in `11-secrets/`. Neither
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
