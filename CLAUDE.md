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

# Provider lock files
mise run lock            # Re-generate every root's .terraform.lock.hcl for darwin_arm64 + linux_amd64

# Linting
actionlint .github/workflows/*.yml   # Lint GitHub Actions workflows (also runs as pre-push hook)
```

### Re-running `providers lock`

The `.terraform.lock.hcl` in each root must cover **both** `darwin_arm64` (local dev) and `linux_amd64` (CI). Re-run `mise run lock` whenever you:

- bump a provider version constraint in any `version.tf`
- add a new provider to a root
- see a CI failure on the `Verify Terraform Lock Files` workflow

`mise run lock` is equivalent to:

```bash
terraform -chdir=terraform-state-bucket providers lock -platform=darwin_arm64 -platform=linux_amd64
terraform -chdir=cluster/local          providers lock -platform=darwin_arm64 -platform=linux_amd64
terraform -chdir=cluster/scaleway       providers lock -platform=darwin_arm64 -platform=linux_amd64
terraform -chdir=github-ci              providers lock -platform=darwin_arm64 -platform=linux_amd64
terraform -chdir=aws-github-oidc        providers lock -platform=darwin_arm64 -platform=linux_amd64
terraform -chdir=s3-lister-role         providers lock -platform=darwin_arm64 -platform=linux_amd64
```

Commit the updated lock files alongside the version change.

## Architecture

Several Terraform root modules. One (./terraform-state-bucket) manage the shared terraform state bucket; any
others cloud-based environments will store it's data on it.

```
terraform-state-bucket/   # shared AWS S3 bucket holding every root's remote state
cluster/
  local/      # minikube — local dev and debugging. Using local backend (e.g. local files)
  scaleway/   # Scaleway Kapsule cluster + ArgoCD bootstrap (homelab; WIP, not yet wired into mise)
github-ci/        # Scaleway IAM identity GitHub Actions authenticates with
aws-github-oidc/  # keyless GitHub-OIDC -> AWS role for CI (Terraform state + bounded IAM)
```

Otherwise, this repo, for now, is an agregate of terraform root modules without specific structure yet.

### `./clusters/*`

Terraform here is only a **one-time bootstrapper** — everything after ArgoCD is up lives in the `gitops` repo. The cluster internal state nor status will be reflected in the terraform state. 

### `cluster/local/`

Warning : This environment expect you an accessible local kubernetes cluster access, likely configured within your ~/.kube/config. This is automatically handled via `mise run dev`

Two-step, one-time bootstrap:
1. Fetch secrets from **Infisical** (universal auth machine identity). Credentials come from `nico.auto.tfvars` (per-developer, not shared).
2. Deploy **ArgoCD** via Helm with the admin bcrypt password hash from Infisical (pre-hashed to prevent Terraform drift).
3. Deploy the **argocd-apps bootstrap** Application, pointing ArgoCD at `https://github.com/IntegratedDynamic/gitops.git`. ArgoCD then self-manages all further cluster state from that separate GitOps repo.

### `cluster/scaleway/`

Same bootstrap pattern as `local/`, but with the Kapsule cluster + node pool (`DEV1-M`, min=0/max=3) instead.

### `github-ci/`

Standalone root (not under `cluster/` — provisions no cluster) that stands up the **Scaleway IAM identity GitHub Actions uses to authenticate to Scaleway**: a dedicated IAM application + a least-privilege policy (`ObjectStorageReadOnly`, project-scoped) + an API key, with the key written into Infisical. GitHub secrets (`SCW_ACCESS_KEY` / `SCW_SECRET_KEY`) are still set manually via `gh secret set`. Keyless GitHub-OIDC → Scaleway is a non-goal — blocked upstream (Scaleway IAM is not an OIDC relying party). See `github-ci/README.md`.

### `aws-github-oidc/`

Standalone root (provisions no cluster) for **keyless GitHub-OIDC → AWS** CI access, built on the `terraform-aws-modules/iam` modules: an OIDC provider + a role (`github-actions-terraform`) GitHub Actions assumes via short-lived tokens (trust scoped to `repo:IntegratedDynamic/infrastructure:*`). The role grant (`tf-managed-ci`) gives Terraform-state R/W on the state bucket **plus privilege-escalation-safe IAM role management**. Applied locally by an admin; `role_arn` is wired to CI via `vars.AWS_GITHUB_ACTIONS_ROLE_ARN`. See `aws-github-oidc/README.md`.

**Permissions-boundary contract (repo-wide):** any `aws_iam_role` that the CI applies **must** set `permissions_boundary` (= the `permissions_boundary_arn` output, `tf-managed-boundary`) and `path` (= the `managed_path` output, `/tf-managed/<org>/<repo>/`), or the apply is rejected by the CI grant's conditions. In CI, feed the path via `TF_VAR_role_path=/tf-managed/${{ github.repository }}/`. The boundary caps every CI-created role to "admin minus a hardened deny-list" so a role-creating role can't escalate. Rationale is documented inline in `aws-github-oidc/iam-ci.tf`.

## Conventions

**Branches**: `<type>/<description>` — lowercase, hyphens only. Types: `feature/`, `bugfix/`, `hotfix/`, `ci/`, `chore/`.

**Commits**: Conventional Commits — `<type>[scope]: <description>`. Types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `chore`, `ci`.

**PRs**: After each commit + push on a branch, create a draft PR if none exists. Title: `<type>: description`. Body: context, changes, linked issues (`Closes #123`), test instructions. Use [Conventional Comments](https://conventionalcomments.org/) in reviews (`praise`, `nitpick`, `suggestion`, `issue`, `todo`, `question`, `thought`).
