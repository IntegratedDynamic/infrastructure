# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Setup

```bash
mise install          # Install all tools (kubectl, minikube, terraform, helm, argocd, actionlint)
.githooks/install.sh  # Configure git to use local hooks directory
```

## Commands

```bash
# Local cluster (minikube)
mise run dev             # Full local env: start minikube + terraform init + apply
mise run reset           # Destroy minikube cluster

# Scaleway cluster (homelab)
mise run scaleway-up     # Provision Kapsule cluster + bootstrap ArgoCD
mise run scaleway-pause  # Scale node pool to 0 (stop paying for nodes)
mise run scaleway-resume # Scale node pool back to 1
mise run scaleway-provision  # Kapsule infra only (cluster/scaleway/kapsule)
mise run scaleway-apps       # ArgoCD bootstrap only (cluster/scaleway/apps)

# Linting
actionlint .github/workflows/*.yml   # Lint GitHub Actions workflows (also runs as pre-push hook)
```

## Architecture

Two cluster environments, three independent Terraform root modules:

```
cluster/
  local/          # minikube — local dev and debugging
  scaleway/
    kapsule/      # Scaleway Kapsule cluster + node pool provisioning
    apps/         # ArgoCD bootstrap (same pattern as local, targets Scaleway kubeconfig)
github_oidc/      # AWS IAM OIDC trust for GitHub Actions
```

### `cluster/local/` and `cluster/scaleway/apps/`

Both follow the same two-step bootstrap pattern:
1. Fetch secrets from **Infisical** (universal auth machine identity). Credentials come from `nico.auto.tfvars` (per-developer, not shared).
2. Deploy **ArgoCD** via Helm with the admin bcrypt password hash from Infisical (pre-hashed to prevent Terraform drift).
3. Deploy the **argocd-apps bootstrap** chart, pointing ArgoCD at `https://github.com/IntegratedDynamic/gitops.git`. ArgoCD then self-manages all further cluster state from that separate GitOps repo.

Terraform here is only a **one-time bootstrapper** — everything after ArgoCD is up lives in the `gitops` repo.

### `cluster/scaleway/kapsule/`

Provisions the Scaleway Kapsule cluster and a single node pool (`DEV1-M`, min=0/max=3). After apply it writes the kubeconfig to `~/.kube/scaleway-homelab.yaml`, which the `apps/` module reads. The `node_count` variable controls pool size — set to `0` via `scaleway-pause` to stop paying for nodes while keeping the (free) control plane running.

Credentials (`scaleway_access_key`, `scaleway_secret_key`, `scaleway_project_id`) come from `nico.auto.tfvars` — fill these in after creating a Scaleway account and generating an API key.

### `github_oidc/`

Targets **AWS** (`eu-west-3`, profile `Sandbox`). Provisions the GitHub OIDC trust so GitHub Actions can assume AWS roles without static credentials. State is in S3 (`terraform-states20260401151521472800000001`, key `github-oidc/`). No mise tasks — run `terraform` commands directly from this directory.

## Conventions

**Branches**: `<type>/<description>` — lowercase, hyphens only. Types: `feature/`, `bugfix/`, `hotfix/`, `ci/`, `chore/`.

**Commits**: Conventional Commits — `<type>[scope]: <description>`. Types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `chore`, `ci`.

**PRs**: After each commit + push on a branch, create a draft PR if none exists. Title: `<type>: description`. Body: context, changes, linked issues (`Closes #123`), test instructions. Use [Conventional Comments](https://conventionalcomments.org/) in reviews (`praise`, `nitpick`, `suggestion`, `issue`, `todo`, `question`, `thought`).
