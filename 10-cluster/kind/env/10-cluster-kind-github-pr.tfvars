# Base tfvars for kind.yml's own run of this root -- named github-pr since
# that's the only real invocation context this file exists for today (no
# local-dev counterpart the way 10-cluster/scaleway's env/*.tfvars has one
# per real environment; this root has no backend/workspace at all -- see
# version.tf's own header comment -- so this filename is purely the
# "which set of default variable values" convention CLAUDE.md documents,
# not a workspace name).
#
# infra_revision is deliberately NOT set here: it's the PR's own head ref,
# genuinely dynamic per run -- kind.yml appends it fresh into a COPY of
# this file every run, same "generate a per-run tfvars, never commit the
# generated one" pattern .github/workflows/scaleway-ephemeral.yml already
# uses for the exact same reason (infra_revision there too).
#
# gitops_revision: pinned to gitops's epic/kind-ci-fast-tier branch, not
# left at its "main" default (10-cluster/kind/variables.tf) -- NOT a
# temporary test-before-merge override like every other *_revision pin in
# this repo. This tier's own companion gitops-side fixes (services/platform/
# openbao/chart's values-kind.yaml, cert-restore/grafana-restore's
# values-kind.yaml, velero's enableCSISnapshotClass, gateway/config's
# clusterissuer-selfsigned.yaml, openbao/init's hook-delete-policy
# removal, external-dns's values-kind.yaml) all live ONLY on that branch
# -- gitops main doesn't have any of them yet, so kind.yml's own DAG
# can't actually converge against main at all right now. Both this root's
# own PRs (infra#112, gitops#63) were merged into their respective
# epic/kind-ci-fast-tier branches rather than straight to main (2026-09-17
# -- the wider infra#110 epic isn't done yet). Flip back to
# 10-cluster/kind/variables.tf's own "main" default (by deleting this
# line) once the epic itself merges to gitops main.
gitops_revision = "epic/kind-ci-fast-tier"
