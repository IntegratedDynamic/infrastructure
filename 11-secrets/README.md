# 11-secrets — what this domain is for

Terraform-managed OpenBao: its auth methods, mounts, policies, and secret
content. That's it — this domain is IaC for OpenBao's own configuration, not
the identities used to reach it (`01-iam`) or anything else.

One service lives here today: [`openbao/`](openbao/README.md), split into
two roots — `bootstrap/` mints a minimal Kubernetes-auth trust anchor
Crossplane's own Workspace needs to self-bootstrap the other root,
`managed/` (OpenBao's actual structure and secret content). Neither root
runs on a static AppRole secret anymore (removed 2026-09-30, infra#115
follow-up) — read `openbao/README.md` for the full "why" and history.
