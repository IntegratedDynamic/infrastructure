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
- **Ends by deploying ArgoCD pointed at the `gitops` repo.** That's the
  handoff point: everything downstream of it is declarative GitOps, not
  Terraform.
- **One variant per target.** `local/` (minikube, for local dev — still
  reads bootstrap secrets from Infisical, one of the few places in this repo
  that still does) and `scaleway/` (the real Kapsule cluster) follow the same
  three-step shape (fetch bootstrap secrets → deploy ArgoCD → deploy the
  `argocd-apps` bootstrap Application) but are otherwise independent roots,
  not a shared module — the two environments diverge enough (local
  minikube vs. a real managed cluster + node pool) that forcing a shared
  abstraction would cost more than it'd save.

## What deliberately doesn't belong here

- Anything that runs *on* the cluster once ArgoCD exists — that's `gitops`.
- Numbered low (moved from `02-` to `10-`) on purpose: this domain sits
  downstream of every identity/storage/encryption domain that precedes it
  numerically, and freed up low numbers for domains that are actually part
  of the early bootstrap chain.
