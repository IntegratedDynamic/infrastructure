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
  definitions themselves live in this repo (`scaleway/platform-apps/`), the
  actual product charts they point at are the `gitops` repo's.
- **Two variants, sharing their orchestration through `modules/`.** `kind/`
  (an ephemeral, disposable cluster — fast, free, on-every-PR validation,
  infra#110/#112) and `scaleway/` (the real Kapsule homelab cluster) each
  provision a genuinely different cluster (a throwaway `kind` cluster
  created by a CI step vs. a real Scaleway-managed Kapsule cluster + node
  pool) and wire ArgoCD to a genuinely different login/exposure story (none
  vs. a real shared Dex/OIDC), so those parts stay separate, independent
  code. But the platform-apps DAG itself — which ArgoCD Applications exist,
  in what order, gated by what `wait-argocd-apps-healthy` mechanism — used
  to be hand-duplicated Terraform between the two roots (`argocd.tf` in
  particular). infra#113 extracted that shared shape into `modules/`
  (`argocd-platform-domain`, `wait-argocd-apps-healthy`, `argocd-wait-rbac`,
  `argocd-base-values`) so each root's own `argocd.tf` only has to state
  its own environment-specific config — which domains it wires up, the
  dependency graph between them, and per-domain Application parameters —
  not re-implement the DAG-building machinery itself. See
  `modules/argocd-platform-domain/main.tf` for why the per-domain module
  deliberately does NOT also own its wait gate (soft vs. hard cross-domain
  dependencies would otherwise collapse into always-hard), and
  `scaleway/platform-apps/README.md` for the platform-wide DAG this wiring
  encodes.
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
