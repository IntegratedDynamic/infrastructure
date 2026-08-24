# 05-secrets — what this domain is for

Terraform-managed OpenBao: its auth methods, mounts, policies, and secret
content. That's it — this domain is IaC for OpenBao's own configuration, not
the identities used to reach it (`01-iam`) or anything else.

One service lives here today: [`openbao/`](openbao/README.md), split into
two roots — `bootstrap/` mints the one AppRole identity everything else
authenticates as (human-applied, rare changes), `managed/` is OpenBao's
actual structure and secret content, reconciled via that AppRole. Read
`openbao/README.md` for the actual detail (the self-init pattern, the CI
feedback loop).
