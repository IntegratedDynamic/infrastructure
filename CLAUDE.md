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
terraform -chdir=state/00-backend      providers lock -platform=darwin_arm64 -platform=linux_amd64
terraform -chdir=state/10-access       providers lock -platform=darwin_arm64 -platform=linux_amd64
terraform -chdir=identity/00-ci-trust  providers lock -platform=darwin_arm64 -platform=linux_amd64
terraform -chdir=ci/10-scaleway        providers lock -platform=darwin_arm64 -platform=linux_amd64
terraform -chdir=cluster/local         providers lock -platform=darwin_arm64 -platform=linux_amd64
terraform -chdir=cluster/scaleway      providers lock -platform=darwin_arm64 -platform=linux_amd64
```

Commit the updated lock files alongside the version change.

## Architecture

Terraform roots are organized by **domain** (top-level folder = what the root is
responsible for) with a **numeric strata prefix** on each root (apply order /
blast-radius / who applies it: `00` = admin-applied foundation, `10`+ = built on
top). The shared S3 state bucket (`state/00-backend`) holds every root's remote
state.

```
modules/                 # reusable Terraform modules (empty for now)
state/                   # domain: Terraform state
  00-backend/            #   shared AWS S3 bucket holding every root's remote state (admin-applied)
  10-access/             #   org-wide read-only state-access IAM role (created BY CI)
identity/                # domain: CI identity & governance
  00-ci-trust/           #   GitHub OIDC provider + role-creator role + permissions boundary + CI grant
ci/                      # domain: CI access
  10-scaleway/           #   Scaleway IAM identity (static API key) GitHub Actions authenticates with
cluster/                 # domain: the Kubernetes platform (de-facto strata 20)
  local/                 #   minikube — local dev and debugging. Local backend (local files)
  scaleway/              #   Scaleway Kapsule cluster + ArgoCD bootstrap (homelab; WIP)
```

**Backend keys are decoupled from paths.** Each root keeps its original
`workspace_key_prefix` (e.g. `state/10-access` still uses prefix `s3-lister-role`)
so the by-domain restructure was a pure move with no state migration. Don't
"fix" a prefix to match its path unless you also migrate the state.

### `cluster/*`

Terraform here is only a **one-time bootstrapper** — everything after ArgoCD is up lives in the `gitops` repo. The cluster internal state nor status will be reflected in the terraform state. 

### `cluster/local/`

Warning : This environment expect you an accessible local kubernetes cluster access, likely configured within your ~/.kube/config. This is automatically handled via `mise run dev`

Two-step, one-time bootstrap:
1. Fetch secrets from **Infisical** (universal auth machine identity). Credentials come from `nico.auto.tfvars` (per-developer, not shared).
2. Deploy **ArgoCD** via Helm with the admin bcrypt password hash from Infisical (pre-hashed to prevent Terraform drift).
3. Deploy the **argocd-apps bootstrap** Application, pointing ArgoCD at `https://github.com/IntegratedDynamic/gitops.git`. ArgoCD then self-manages all further cluster state from that separate GitOps repo.

### `cluster/scaleway/`

Same bootstrap pattern as `local/`, but with the Kapsule cluster + node pool (`DEV1-M`, min=0/max=3) instead.

### `state/00-backend/`

The shared org S3 bucket holding **every** root's remote state (built on `terraform-aws-modules/s3-bucket`: versioning, SSE, public-access block, TLS-only). Chicken-and-egg: its own state lives in the bucket it creates (one-time local-state bootstrap — see its README). Applied by an admin.

### `state/10-access/`

Org-wide, read-only S3-lister IAM **role created BY the CI** (the first role minted by `identity/00-ci-trust`'s role-creator rather than by a human). Assumable org-wide via two trust doors: AWS principals in the org (`aws:PrincipalOrgID`) and GitHub Actions in the org via OIDC (`repo:IntegratedDynamic/*`). Its true responsibility is **read access to the Terraform state** — used e.g. by the `scaleway-plan` workflow. Applied by CI (`s3-lister-role.yml`).

### `ci/10-scaleway/`

Standalone root that stands up the **Scaleway IAM identity GitHub Actions uses to authenticate to Scaleway**: a dedicated IAM application + a least-privilege policy (`ObjectStorageReadOnly`, project-scoped) + an API key, with the key written into Infisical. GitHub secrets (`SCW_ACCESS_KEY` / `SCW_SECRET_KEY`) are still set manually via `gh secret set`. Keyless GitHub-OIDC → Scaleway is a non-goal — blocked upstream (Scaleway IAM is not an OIDC relying party). See `ci/10-scaleway/README.md`.

### `identity/00-ci-trust/`

The CI **identity & governance foundation**: **keyless GitHub-OIDC → AWS** access, built on the `terraform-aws-modules/iam` modules. An OIDC provider + a role (`github-actions-terraform`) GitHub Actions assumes via short-lived tokens (trust scoped to `repo:IntegratedDynamic/infrastructure:*`). The role grant (`tf-managed-ci`) gives Terraform-state R/W on the state bucket **plus privilege-escalation-safe IAM role management** — i.e. it is the role that **creates other CI roles** (e.g. `state/10-access`). Applied locally by an admin; `role_arn` is wired to CI via `vars.AWS_GITHUB_ACTIONS_ROLE_ARN`. See `identity/00-ci-trust/README.md`.

**Permissions-boundary contract (repo-wide):** any `aws_iam_role` that the CI applies **must** set `permissions_boundary` (= the `permissions_boundary_arn` output, `tf-managed-boundary`) and `path` (= the `managed_path` output, `/tf-managed/<org>/<repo>/`), or the apply is rejected by the CI grant's conditions. Set both via the root's `env/<name>.tfvars` (see the Terraform workspaces convention below). The boundary caps every CI-created role to "admin minus a hardened deny-list" so a role-creating role can't escalate. Rationale is documented inline in `identity/00-ci-trust/iam-ci.tf`.

## Conventions

**Branches**: `<type>/<description>` — lowercase, hyphens only. Types: `feature/`, `bugfix/`, `hotfix/`, `ci/`, `chore/`.

**Commits**: Conventional Commits — `<type>[scope]: <description>`. Types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `chore`, `ci`.

**PRs**: After each commit + push on a branch, create a draft PR if none exists. Title: `<type>: description`. Body: context, changes, linked issues (`Closes #123`), test instructions. Use [Conventional Comments](https://conventionalcomments.org/) in reviews (`praise`, `nitpick`, `suggestion`, `issue`, `todo`, `question`, `thought`).

**Terraform workspaces**: a root that runs through CI declares its workspace variables in an `env/` folder — one `env/<name>.tfvars` per workspace. The **filename (without `.tfvars`) is the terraform workspace name** (so state lands at `<workspace_key_prefix>/<name>/<key>`, isolated per root) and the **file contents are that workspace's variable values**. The reusable composite action `.github/actions/terraform` takes `root` + `tfvars-file` inputs and runs `workspace select <name>` + `plan`/`apply -var-file=env/<name>.tfvars` after assuming an AWS role via OIDC. The repo must be checked out before calling this action (it is a local action). This replaces the old reliance on a local, gitignored `.terraform/environment` (invisible to CI — a `default`-workspace run collides on the state key).
