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
terraform -chdir=00-remote_state                    providers lock -platform=darwin_arm64 -platform=linux_amd64
terraform -chdir=01-iam/bootstrap/aws               providers lock -platform=darwin_arm64 -platform=linux_amd64
terraform -chdir=01-iam/bootstrap/scaleway          providers lock -platform=darwin_arm64 -platform=linux_amd64
terraform -chdir=01-iam/bootstrap/infisical         providers lock -platform=darwin_arm64 -platform=linux_amd64
terraform -chdir=01-iam/ci-managed/aws-state-access providers lock -platform=darwin_arm64 -platform=linux_amd64
terraform -chdir=02-cluster/local                   providers lock -platform=darwin_arm64 -platform=linux_amd64
terraform -chdir=02-cluster/scaleway                providers lock -platform=darwin_arm64 -platform=linux_amd64
```

Commit the updated lock files alongside the version change.

## Architecture

Terraform roots are organized by **domain** — the top-level folder is a numeric
**pseudo-ID** for what that domain owns (`00-remote_state`, `01-iam`,
`02-cluster`). The number encodes apply order / blast-radius across domains
(`00` first, built on by `01`, then `02`). The shared S3 state bucket
(`00-remote_state`) holds every root's remote state.

Within a domain, sub-folders split roots by the **second axis: lifecycle / who
applies them** — `bootstrap/` = human/admin-applied trust anchors (rare changes,
need admin creds), `ci-managed/` = roots minted BY the CI (GitOps, capped by the
permissions boundary). A domain with a single root is flattened (the domain
folder *is* the root, e.g. `00-remote_state`).

```
modules/                       # reusable Terraform modules (empty for now)
00-remote_state/               # domain: Terraform state backend — the shared AWS
                               #   S3 bucket holding every root's remote state (admin-applied)
01-iam/                        # domain: IAM identities & grants
  bootstrap/                   #   human-applied trust anchors
    aws/                       #     GitHub-OIDC → AWS: OIDC provider + role-creator role
                               #       + permissions boundary + CI grant
    scaleway/                  #     Scaleway CI identity (IAM app + project policy + static API key)
    infisical/                 #     Infisical CI identity (keyless GitHub-OIDC → Infisical)
  ci-managed/                  #   minted BY the CI, capped by the boundary
    aws-state-access/          #     org-wide tf-state-access role (the first CI-minted role)
02-cluster/                    # domain: the Kubernetes platform
  local/                       #   minikube — local dev and debugging. Local backend (local files)
  scaleway/                    #   Scaleway Kapsule cluster + ArgoCD bootstrap (homelab; WIP)
```

**The dependency spine** runs strictly forward: `00-remote_state` (bucket) →
`01-iam/bootstrap/aws` (the trust anchor that lets CI apply anything) →
`01-iam/ci-managed/*` (roles the anchor mints) → `02-cluster/*`. `bootstrap/aws`
is the root of trust — nothing CI-applied can exist before it.

**Backend keys are decoupled from paths.** Each root pins its own
`workspace_key_prefix` in `version.tf` (e.g. `01-iam/ci-managed/aws-state-access`
still uses prefix `s3-lister-role`), and the workspace name comes from the
`env/<name>.tfvars` filename — **neither is tied to the directory**. The
restructure was a pure `git mv` with no state migration. Don't "fix" a prefix or
rename a tfvars file to match its new path unless you also migrate the state
(renaming the tfvars file changes the workspace, hence the state key). This is
why some workspace names look dated (e.g. `aws-state-access` still uses the
`00-remote-state-iam` workspace).

### `02-cluster/*`

Terraform here is only a **one-time bootstrapper** — everything after ArgoCD is up lives in the `gitops` repo. The cluster internal state nor status will be reflected in the terraform state. 

### `02-cluster/local/`

Warning : This environment expect you an accessible local kubernetes cluster access, likely configured within your ~/.kube/config. This is automatically handled via `mise run dev`

Two-step, one-time bootstrap:
1. Fetch secrets from **Infisical** (universal auth machine identity). Credentials come from `nico.auto.tfvars` (per-developer, not shared).
2. Deploy **ArgoCD** via Helm with the admin bcrypt password hash from Infisical (pre-hashed to prevent Terraform drift).
3. Deploy the **argocd-apps bootstrap** Application, pointing ArgoCD at `https://github.com/IntegratedDynamic/gitops.git`. ArgoCD then self-manages all further cluster state from that separate GitOps repo.

### `02-cluster/scaleway/`

Same bootstrap pattern as `local/`, but with the Kapsule cluster + node pool (`DEV1-M`, min=0/max=3) instead.

### `00-remote_state/`

The shared org S3 bucket holding **every** root's remote state (built on `terraform-aws-modules/s3-bucket`: versioning, SSE, public-access block, TLS-only). Chicken-and-egg: its own state lives in the bucket it creates (one-time local-state bootstrap — see its README). Applied by an admin.

### `01-iam/ci-managed/aws-state-access/`

Org-wide Terraform-state **access** IAM **role created BY the CI** (the first role minted by `01-iam/bootstrap/aws`'s role-creator rather than by a human). Named `tf-state-access`, it grants `AmazonS3FullAccess` — **read/write on the state bucket plus the state lock** — so every state-touching workflow assumes it for `plan` AND `apply`/`destroy` alike (e.g. the `scaleway` workflow), wired via `vars.AWS_TF_STATE_ROLE_ARN`. Assumable org-wide via two trust doors: AWS principals in the org (`aws:PrincipalOrgID`) and GitHub Actions in the org via OIDC (`repo:IntegratedDynamic/*`). Applied by CI (`iam_terraform-backend-role.yml`).

### `01-iam/bootstrap/scaleway/`

Standalone root that stands up the **Scaleway IAM identity GitHub Actions uses to authenticate to Scaleway**: a dedicated IAM application + a project-scoped policy (`Kubernetes`/`VPC`/`PrivateNetworks` FullAccess + `IPAMReadOnly`, enough for CI to create/destroy the Kapsule cluster) + an API key, with the key written into Infisical. GitHub secrets (`SCW_ACCESS_KEY` / `SCW_SECRET_KEY`) are still set manually via `gh secret set`. Keyless GitHub-OIDC → Scaleway is a non-goal — blocked upstream (Scaleway IAM is not an OIDC relying party). See `01-iam/bootstrap/scaleway/README.md`.

### `01-iam/bootstrap/infisical/`

The **keyless GitHub-OIDC → Infisical** counterpart to `bootstrap/scaleway`: a Infisical machine identity + OIDC auth trusting GitHub Actions tokens, so the composite action can mint a short-lived Infisical token (no static Infisical secret) to read the secrets cluster bootstraps need. See `01-iam/bootstrap/infisical/README.md`.

### `01-iam/bootstrap/aws/`

The CI **identity & governance foundation**: **keyless GitHub-OIDC → AWS** access, built on the `terraform-aws-modules/iam` modules. An OIDC provider + a role (`github-actions-terraform`) GitHub Actions assumes via short-lived tokens (trust scoped to `repo:IntegratedDynamic/infrastructure:*`). The role grant (`tf-managed-ci`) gives Terraform-state R/W on the state bucket **plus privilege-escalation-safe IAM role management** — i.e. it is the role that **creates other CI roles** (e.g. `01-iam/ci-managed/aws-state-access`). Applied locally by an admin; `role_arn` is wired to CI via `vars.AWS_GITHUB_ACTIONS_ROLE_ARN`. See `01-iam/bootstrap/aws/README.md`.

**Permissions-boundary contract (repo-wide):** any `aws_iam_role` that the CI applies **must** set `permissions_boundary` (= the `permissions_boundary_arn` output, `tf-managed-boundary`) and `path` (= the `managed_path` output, `/tf-managed/<org>/<repo>/`), or the apply is rejected by the CI grant's conditions. Set both via the root's `env/<name>.tfvars` (see the Terraform workspaces convention below). The boundary caps every CI-created role to "admin minus a hardened deny-list" so a role-creating role can't escalate. Rationale is documented inline in `01-iam/bootstrap/aws/iam-ci.tf`.

## Conventions

**Branches**: `<type>/<description>` — lowercase, hyphens only. Types: `feature/`, `bugfix/`, `hotfix/`, `ci/`, `chore/`.

**Commits**: Conventional Commits — `<type>[scope]: <description>`. Types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `chore`, `ci`.

**PRs**: After each commit + push on a branch, create a draft PR if none exists. Title: `<type>: description`. Body: context, changes, linked issues (`Closes #123`), test instructions. Use [Conventional Comments](https://conventionalcomments.org/) in reviews (`praise`, `nitpick`, `suggestion`, `issue`, `todo`, `question`, `thought`).

**Terraform workspaces**: a root that runs through CI declares its workspace variables in an `env/` folder — one `env/<name>.tfvars` per workspace. The **filename (without `.tfvars`) is the terraform workspace name** (so state lands at `<workspace_key_prefix>/<name>/<key>`, isolated per root) and the **file contents are that workspace's variable values**. The reusable **composite action `.github/actions/terraform`** takes `root` + `tfvars-file` + `command` (`plan`/`apply`/`destroy`) + `aws-role-arn` (all non-secret inputs) and runs `workspace select <name>` + the command `-var-file=env/<name>.tfvars`, after minting an Infisical OIDC token (skippable) and assuming the AWS role via OIDC. The action takes **no secret inputs**: provider credentials (`SCW_*`, `INFISICAL_MACHINE_IDENTITY_ID`) are read from the job env. The calling **workflow** owns the trigger→command mapping (push → apply, schedule → destroy, else plan), the `concurrency` guard, and the `environment` that scopes credentials — Scaleway keys live in the `scaleway` environment and are exposed to the action as job `env:` (never as plain inputs). The repo must be checked out before calling the action (it is a local action). This replaces the old reliance on a local, gitignored `.terraform/environment` (invisible to CI — a `default`-workspace run collides on the state key).
