# 11-secrets — what this domain is for

Terraform-managed OpenBao: its auth methods, mounts, policies, and secret
content. That's it — this domain is IaC for OpenBao's own configuration, not
the identities used to reach it (`01-iam`) or anything else.

One service lives here today: [`openbao/`](openbao/README.md) — just
`managed/`, OpenBao's actual structure and secret content. (Used to be
split into two roots — `bootstrap/` minted an AppRole identity `managed/`
authenticated as; deleted entirely 2026-09-30, infra#115 follow-up, once
OIDC (laptop) and Kubernetes auth (in-cluster Crossplane Workspace) covered
every real execution context with no static secret to manage. Read
`openbao/README.md` for the full "why" and what used to live there.)
