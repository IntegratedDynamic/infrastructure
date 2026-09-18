# 10-cluster — what this domain is for

Stands up a Kubernetes cluster and hands it off to ArgoCD. That's the whole
job — everything that runs on the cluster afterward, including how the
cluster's own workloads get configured, is the `gitops` repo's
responsibility, not this domain's.

## The contract

- **One-time bootstrapper, not an ongoing reconciler.** The cluster's
  internal state and workload status are never reflected in this root's
  Terraform state — once ArgoCD is up, this root's job is done until the
  cluster itself needs to change shape (node pool size, region, etc.).
- **Ends by deploying ArgoCD and handing it a DAG of Applications to
  reconcile.** That's the handoff point: everything downstream of it is
  declarative GitOps, not Terraform — even though the top-level Application
  definitions themselves live in this repo (`platform-apps/`, shared at this
  domain's root — infra#115, not nested under either `kind/` or `scaleway/`),
  the actual product charts they point at are the `gitops` repo's.
- **Two variants, sharing their orchestration through ONE module.** `kind/`
  (an ephemeral, disposable cluster — fast, free, on-every-PR validation,
  infra#110/#112) and `scaleway/` (the real Kapsule homelab cluster) each
  provision a genuinely different cluster (a throwaway `kind` cluster
  created by a CI step vs. a real Scaleway-managed Kapsule cluster + node
  pool) and wire ArgoCD to a genuinely different login/exposure story (none
  vs. a real shared Dex/OIDC), so those parts stay separate, independent
  code. But the platform-apps DAG itself — which ArgoCD Applications exist,
  gated by what — used to be hand-duplicated Terraform between the two
  roots (`argocd.tf` in particular), then (infra#113, first pass) extracted
  into four separate shared modules each root still had to hand-wire once
  per domain. infra#113's actual landing shape is a single module,
  `modules/platform-apps-dag`, driven entirely by a `domains` map each
  root declares — mostly sourced straight from `env/*.tfvars` — so a root's
  own `argocd.tf` only has to state genuinely environment-specific config
  (provider/cluster bootstrapping, OIDC/Dex vs. none, the handful of truly
  dynamic values no tfvars literal could express) and call the module
  once. A fully free-form named cross-domain graph turned out not to be
  expressible this way at all (confirmed live 2026-09-17: a self-
  referencing `for_each` is a real OpenTofu cycle) — see
  `modules/platform-apps-dag/main.tf`'s own header comment for why this
  platform's real DAG instead reduces to six independently-named gates
  (`crds-apps`/`secrets-apps`/`backups-apps`/`dex-apps`/
  `networking-controllers-apps`/`grafana-apps`), each its own resource
  address so the graph stays acyclic while every domain that doesn't need
  a gate still runs in full parallel. See `platform-apps/README.md`
  for the platform-wide DAG this wiring encodes.
- **The old `local/` (minikube) variant was removed entirely (infra#113).**
  It never shared the platform-apps DAG structure at all (it deployed only
  ArgoCD + a single `bootstrap` Application, none of the domain-by-domain
  DAG `kind/`/`scaleway/` both drive) and was redundant with `kind/` as a
  fast, disposable Kubernetes target for local iteration.

## What deliberately doesn't belong here

- Anything that runs *on* the cluster once ArgoCD exists — that's `gitops`.
- Numbered low (moved from `02-` to `10-`) on purpose: this domain sits
  downstream of every identity/storage/encryption domain that precedes it
  numerically, and freed up low numbers for domains that are actually part
  of the early bootstrap chain.
