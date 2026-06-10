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

# Linting
actionlint .github/workflows/*.yml   # Lint GitHub Actions workflows (also runs as pre-push hook)
```

## Architecture

Two cluster environments, each its own Terraform root module:

```
cluster/
  local/      # minikube — local dev and debugging
  scaleway/   # Scaleway Kapsule cluster + ArgoCD bootstrap (homelab; WIP, not yet wired into mise)
```

### `cluster/local/`

Two-step, one-time bootstrap:
1. Fetch secrets from **Infisical** (universal auth machine identity). Credentials come from `nico.auto.tfvars` (per-developer, not shared).
2. Deploy **ArgoCD** via Helm with the admin bcrypt password hash from Infisical (pre-hashed to prevent Terraform drift).
3. Deploy the **argocd-apps bootstrap** chart, pointing ArgoCD at `https://github.com/IntegratedDynamic/gitops.git`. ArgoCD then self-manages all further cluster state from that separate GitOps repo.

Terraform here is only a **one-time bootstrapper** — everything after ArgoCD is up lives in the `gitops` repo.

### `cluster/scaleway/`

Same bootstrap pattern as `local/`, plus the Kapsule cluster + node pool (`DEV1-M`, min=0/max=3) in one consolidated module. Writes the kubeconfig to `~/.kube/scaleway-homelab.yaml`. Scaleway credentials are read from the `scw` CLI config (`~/.config/scw/config.yaml`), not from tfvars. Still early — intentionally undocumented in the commands above for now.

## Conventions

**Branches**: `<type>/<description>` — lowercase, hyphens only. Types: `feature/`, `bugfix/`, `hotfix/`, `ci/`, `chore/`.

**Commits**: Conventional Commits — `<type>[scope]: <description>`. Types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `chore`, `ci`.

**PRs**: After each commit + push on a branch, create a draft PR if none exists. Title: `<type>: description`. Body: context, changes, linked issues (`Closes #123`), test instructions. Use [Conventional Comments](https://conventionalcomments.org/) in reviews (`praise`, `nitpick`, `suggestion`, `issue`, `todo`, `question`, `thought`).
